import Foundation
import AskKeyCore

@MainActor
final class ICloudAppLifecycleController {
    #if DEBUG && ASKKEY_E2E_TESTING
    static let shared = ICloudAppLifecycleController(
        loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in })
    )
    #else
    static let shared = ICloudAppLifecycleController()
    #endif

    private let makeCloudStore: () throws -> ICloudBackupStore
    private let materials: ICloudBackupMaterialStore
    private let state: ICloudBackupLocalStateStore
    private let safetySnapshots: LocalICloudSafetySnapshotStore
    private let preferences: AppPreferences
    private let loginItem: LoginItemController
    private let inspectCapability: () -> ICloudBackupCapabilityDecision
    private let dirtyDefaults: UserDefaults
    private let dirtyKey: String
    private var scheduler: AutomaticICloudBackupScheduler?
    private var settingsObserver: NSObjectProtocol?
    var installedScheduler: AutomaticICloudBackupScheduler? { scheduler }

    init(
        makeCloudStore: @escaping () throws -> ICloudBackupStore = makeDefaultCloudStore,
        materials: ICloudBackupMaterialStore = SystemICloudBackupMaterialStore(
            service: VaultConfiguration.iCloudBackupKeychainService
        ),
        state: ICloudBackupLocalStateStore = UserDefaultsICloudBackupLocalStateStore(),
        safetySnapshots: LocalICloudSafetySnapshotStore = LocalICloudSafetySnapshotStore(
            directory: VaultConfiguration.localRestoreSafetySnapshotDirectory
        ),
        preferences: AppPreferences = AppPreferences(),
        loginItem: LoginItemController = LoginItemController(),
        inspectCapability: @escaping () -> ICloudBackupCapabilityDecision = {
            ICloudBackupCapabilityInspection.decide(ICloudBackupCapabilityInspection.liveRequest())
        },
        dirtyDefaults: UserDefaults = .standard,
        dirtyKey: String = VaultConfiguration.isDevelopmentBuild
            ? "icloudAutomaticBackupDirty.dev"
            : "icloudAutomaticBackupDirty"
    ) {
        self.makeCloudStore = makeCloudStore
        self.materials = materials
        self.state = state
        self.safetySnapshots = safetySnapshots
        self.preferences = preferences
        self.loginItem = loginItem
        self.inspectCapability = inspectCapability
        self.dirtyDefaults = dirtyDefaults
        self.dirtyKey = dirtyKey
    }

    func capabilityDecision() -> ICloudBackupCapabilityDecision {
        inspectCapability()
    }

    func prepareAgentRuntime(vault: Vault = .shared) throws {
        try vault.prepareAgentRuntime()
        do {
            try vault.recoverPendingICloudRestoreSettings { [self] settings in
                try applyRestoredSettings(settings, vault: vault)
            }
        } catch {
            throw ICloudAppLifecycleError.restoreSettingsRecoveryFailed
        }
    }

    func startAutomaticScheduling(
        vault: Vault = .shared,
        schedule: @escaping AutomaticICloudBackupScheduler.Schedule = AutomaticICloudBackupScheduler.dispatchQueueSchedule(),
        operations: AutomaticBackupOperations? = nil
    ) {
        let makeCloudStore = self.makeCloudStore
        let materials = self.materials
        let state = self.state
        let preferences = self.preferences
        let loginItem = self.loginItem
        let dirtyDefaults = self.dirtyDefaults
        let dirtyKey = self.dirtyKey
        let operations = operations ?? AutomaticBackupOperations(
            backup: {
                try performAutomaticICloudBackup(
                    vault: vault,
                    makeCloudStore: makeCloudStore,
                    materials: materials,
                    state: state,
                    preferences: preferences,
                    loginItem: loginItem
                )
            },
            isEnabled: {
                try automaticBackupIsEnabled(
                    makeCloudStore: makeCloudStore,
                    materials: materials,
                    state: state
                )
            },
            hasPendingUpload: {
                try pendingAutomaticUploadExists(
                    makeCloudStore: makeCloudStore,
                    materials: materials,
                    state: state
                )
            }
        )
        if let scheduler {
            scheduler.replaceOperations(
                backup: operations.backup,
                isEnabled: operations.isEnabled,
                hasPendingUpload: operations.hasPendingUpload
            )
            bindScheduler(scheduler, vault: vault)
            scheduler.compensateOnLaunch()
            return
        }
        let scheduler = AutomaticICloudBackupScheduler(
            backup: operations.backup,
            isEnabled: operations.isEnabled,
            hasPendingUpload: operations.hasPendingUpload,
            loadLedger: { loadChangeLedger(defaults: dirtyDefaults, key: dirtyKey) },
            persistLedger: { persistChangeLedger($0, defaults: dirtyDefaults, key: dirtyKey) },
            schedule: schedule
        )
        self.scheduler = scheduler
        AutomaticICloudBackupScheduler.shared = scheduler
        bindScheduler(scheduler, vault: vault)
        scheduler.compensateOnLaunch()
    }

    private func bindScheduler(_ scheduler: AutomaticICloudBackupScheduler, vault: Vault) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        vault.onSnapshotRelevantChange = { [weak scheduler] in
            scheduler?.noteSuccessfulChange()
        }
        vault.onAutomaticBackupMustStop = { [weak scheduler] in
            scheduler?.cancelPendingWork(clearDirty: false)
        }
        vault.onAutomaticBackupMayResume = { [weak scheduler] in
            scheduler?.resumeScheduling()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .askKeyOrdinaryBackupSettingsDidChange,
            object: nil,
            queue: nil
        ) { [weak scheduler] _ in
            scheduler?.noteSuccessfulChange()
        }
    }

    func inspect(recoveryKey: String) throws -> [ICloudBackupGeneration] {
        try coordinator(recoveryKey: recoveryKey, persistMaterial: false)
            .coordinator.recoverableGenerations()
    }

    func unresolvedConflicts(recoveryKey: String) throws -> [String] {
        try coordinator(recoveryKey: recoveryKey, persistMaterial: false)
            .coordinator.unresolvedConflictPaths()
    }

    func restore(
        recoveryKey: String,
        generationID: String,
        using authenticator: ManagementAuthenticator,
        vault: Vault = .shared
    ) throws -> ICloudBackupGeneration {
        let prepared = try coordinator(recoveryKey: recoveryKey, persistMaterial: true)
        do {
            let target = try VaultICloudBackupRestoreTarget(
                vault: vault,
                currentSettings: { [self] in currentBackupSettings() },
                applySettings: { [self] settings in
                    try applyRestoredSettings(settings, vault: vault)
                }
            )
            return try prepared.coordinator.restoreGeneration(
                generationID,
                into: target,
                using: authenticator,
                persistLocalSafetySnapshot: { [safetySnapshots] in
                    try safetySnapshots.persist($0)
                }
            )
        } catch ICloudBackupError.propagationPending {
            // Immutable objects may already exist but not yet be readable.
            // Preserve the only material capable of retrying/decrypting them.
            throw ICloudBackupError.propagationPending
        } catch ICloudBackupError.cleanupFailed(let primary, let cleanup) {
            // Cleanup failure means cloud ownership is unresolved; deleting the
            // material here could strand an encrypted generation permanently.
            throw ICloudBackupError.cleanupFailed(primary: primary, cleanup: cleanup)
        } catch {
            let primary = error
            if prepared.materialWasCreated {
                do {
                    try materials.delete(keyID: prepared.material.recoveryKey.keyID)
                } catch {
                    throw ICloudBackupError.cleanupFailed(
                        primary: String(describing: primary),
                        cleanup: String(describing: error)
                    )
                }
            }
            throw primary
        }
    }

    func cloudNamespaces() throws -> [String] {
        try ICloudBackupNamespaceManager(
            cloud: makeCloudStore(),
            materials: materials,
            state: state
        ).cloudNamespaces()
    }

    func backUpNow() throws -> ICloudBackupGeneration {
        let cloud = try makeCloudStore()
        let manager = ICloudBackupNamespaceManager(
            cloud: cloud,
            materials: materials,
            state: state
        )
        var activeMaterials: [ICloudBackupKeyMaterial] = []
        var foundMaterial = false
        for namespace in try manager.cloudNamespaces() {
            guard let material = try materials.load(keyID: namespace) else { continue }
            foundMaterial = true
            if try state.isAutomaticBackupPaused(namespace: namespace) { continue }
            activeMaterials.append(material)
        }
        guard activeMaterials.count <= 1 else { throw ICloudBackupError.forkDetected }
        guard let material = activeMaterials.first else {
            throw foundMaterial
                ? ICloudBackupError.automaticBackupPaused
                : ICloudBackupError.invalidRecoveryKey
        }
        return try Vault.shared.backUpToICloud(
            using: ICloudBackupCoordinator(store: cloud, material: material, stateStore: state),
            settings: currentBackupSettings()
        )
    }

    func automaticBackupEnabled() throws -> Bool {
        let manager = ICloudBackupNamespaceManager(
            cloud: try makeCloudStore(),
            materials: materials,
            state: state
        )
        for namespace in try manager.cloudNamespaces()
        where try materials.load(keyID: namespace) != nil {
            if try !state.isAutomaticBackupPaused(namespace: namespace) { return true }
        }
        return false
    }

    func setAutomaticBackupEnabled(_ enabled: Bool) throws -> Bool {
        let manager = ICloudBackupNamespaceManager(
            cloud: try makeCloudStore(),
            materials: materials,
            state: state
        )
        var materialNamespaces: [String] = []
        for namespace in try manager.cloudNamespaces() {
            guard try materials.load(keyID: namespace) != nil else { continue }
            materialNamespaces.append(namespace)
            if !enabled {
                try manager.stopAutomaticBackups(namespace: namespace)
            }
        }
        if !enabled {
            scheduler?.cancelPendingWork(clearDirty: true)
            return false
        }
        // A disabled namespace is never resumed in place: re-enabling must go
        // through createNewBackupNamespace(using:) so the person receives and
        // saves a fresh recovery key before automatic backup starts.
        throw materialNamespaces.count > 1
            ? ICloudBackupError.forkDetected
            : ICloudBackupError.invalidRecoveryKey
    }

    func createNewBackupNamespace(
        using authenticator: ManagementAuthenticator
    ) throws -> String {
        guard authenticator.confirm(reason: "Create a new Ask Key backup namespace") else {
            throw ICloudBackupError.authenticationRequired
        }
        let cloud = try makeCloudStore()
        let manager = ICloudBackupNamespaceManager(
            cloud: cloud,
            materials: materials,
            state: state
        )
        for namespace in try manager.cloudNamespaces() {
            try manager.stopAutomaticBackups(namespace: namespace)
        }
        scheduler?.cancelPendingWork(clearDirty: true)
        let material = try manager.createNewBackupNamespace()
        return material.recoveryKey.encoded
    }

    func activateBackupNamespace(
        recoveryKey: String,
        using authenticator: ManagementAuthenticator
    ) throws -> ICloudBackupGeneration {
        guard authenticator.confirm(reason: "Start Ask Key backup with the saved recovery key") else {
            throw ICloudBackupError.authenticationRequired
        }
        let key = try BackupRecoveryKey(encoded: recoveryKey)
        guard let material = try materials.load(keyID: key.keyID) else {
            throw ICloudBackupError.invalidRecoveryKey
        }
        let generation = try Vault.shared.backUpToICloud(
            using: ICloudBackupCoordinator(store: makeCloudStore(), material: material, stateStore: state),
            settings: currentBackupSettings()
        )
        scheduler?.cancelPendingWork(clearDirty: true)
        scheduler?.resumeScheduling()
        return generation
    }

    func takeOwnership(
        recoveryKey: String,
        generationID: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        guard authenticator.confirm(reason: "Take ownership of Ask Key iCloud backup") else {
            throw ICloudBackupError.authenticationRequired
        }
        let key = try BackupRecoveryKey(encoded: recoveryKey)
        guard let material = try materials.load(keyID: key.keyID) else {
            throw ICloudBackupError.invalidRecoveryKey
        }
        let coordinator = try ICloudBackupCoordinator(
            store: makeCloudStore(),
            material: material,
            stateStore: state
        )
        try coordinator.resumeAfterUserTakesOwnership(of: generationID)
        scheduler?.resumeScheduling()
    }

    func deleteCloudBackup(
        recoveryKey: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        let key = try BackupRecoveryKey(encoded: recoveryKey)
        try ICloudBackupNamespaceManager(
            cloud: makeCloudStore(),
            materials: materials,
            state: state
        ).deleteCloudNamespace(key.keyID, using: authenticator)
        scheduler?.cancelPendingWork(clearDirty: true)
    }

    private func coordinator(
        recoveryKey: String,
        persistMaterial: Bool
    ) throws -> (
        coordinator: ICloudBackupCoordinator,
        material: ICloudBackupKeyMaterial,
        materialWasCreated: Bool
    ) {
        let key = try BackupRecoveryKey(encoded: recoveryKey)
        let existing = try materials.load(keyID: key.keyID)
        let material = try existing ?? ICloudBackupKeyMaterial(
            recoveryKey: key,
            writerID: UUID().uuidString
        )
        if persistMaterial, existing == nil {
            try materials.save(material)
        }
        return (
            try ICloudBackupCoordinator(
                store: makeCloudStore(),
                material: material,
                stateStore: state
            ),
            material,
            persistMaterial && existing == nil
        )
    }

    private func currentBackupSettings() -> ICloudBackupSettings {
        ICloudBackupSettings(
            languageMode: preferences.languageMode,
            appearanceMode: preferences.appearanceMode,
            defaultTimedAllowanceMinutes: preferences.defaultTimedAllowanceMinutes,
            launchAtLogin: loginItem.isEnabled
        )
    }

    private func applyRestoredSettings(_ settings: ICloudBackupSettings, vault: Vault) throws {
        preferences.readApprovalAuthenticationEnabled = true
        vault.resetReadApprovalAuthenticationAfterRestore()
        preferences.languageMode = settings.languageMode
        preferences.appearanceMode = settings.appearanceMode
        AppLanguage.apply(mode: settings.languageMode)
        preferences.defaultTimedAllowanceMinutes = settings.defaultTimedAllowanceMinutes
        vault.updateDefaultTimedAllowanceMinutes(settings.defaultTimedAllowanceMinutes)
        try loginItem.setEnabled(settings.launchAtLogin)
    }
}

enum ICloudAppLifecycleError: Error {
    case restoreSettingsRecoveryFailed
}

struct AutomaticBackupOperations {
    var backup: () throws -> ICloudBackupGeneration
    var isEnabled: () throws -> Bool
    var hasPendingUpload: () throws -> Bool
}

private func loadChangeLedger(defaults: UserDefaults, key: String) -> AutomaticBackupChangeLedger {
    let changeKey = key + ".change"
    let confirmedKey = key + ".confirmed"
    if defaults.object(forKey: changeKey) == nil, defaults.bool(forKey: key) {
        return AutomaticBackupChangeLedger(changeVersion: 1, confirmedVersion: 0)
    }
    return AutomaticBackupChangeLedger(
        changeVersion: defaults.integer(forKey: changeKey),
        confirmedVersion: defaults.integer(forKey: confirmedKey)
    )
}

private func persistChangeLedger(
    _ ledger: AutomaticBackupChangeLedger,
    defaults: UserDefaults,
    key: String
) {
    defaults.set(ledger.changeVersion, forKey: key + ".change")
    defaults.set(ledger.confirmedVersion, forKey: key + ".confirmed")
    defaults.set(ledger.hasUnconfirmedChange, forKey: key)
}

private func makeDefaultCloudStore() throws -> ICloudBackupStore {
    let decision = ICloudBackupCapabilityInspection.decide(
        ICloudBackupCapabilityInspection.liveRequest()
    )
    switch decision {
    case .ready(let identifier):
        return try ICloudFileBackupStore(
            provider: SystemICloudBackupContainerProvider(identifier: identifier)
        )
    case .developmentUnavailable, .releaseMaterialsMissing, .forbiddenContainer, .fixtureUnproven:
        throw ICloudBackupError.capabilityUnavailable
    }
}

private func performAutomaticICloudBackup(
    vault: Vault,
    makeCloudStore: () throws -> ICloudBackupStore,
    materials: ICloudBackupMaterialStore,
    state: ICloudBackupLocalStateStore,
    preferences: AppPreferences,
    loginItem: LoginItemController
) throws -> ICloudBackupGeneration {
    let cloud = try makeCloudStore()
    let manager = ICloudBackupNamespaceManager(
        cloud: cloud,
        materials: materials,
        state: state
    )
    var activeMaterials: [ICloudBackupKeyMaterial] = []
    var foundMaterial = false
    for namespace in try manager.cloudNamespaces() {
        guard let material = try materials.load(keyID: namespace) else { continue }
        foundMaterial = true
        if try state.isAutomaticBackupPaused(namespace: namespace) { continue }
        activeMaterials.append(material)
    }
    guard activeMaterials.count <= 1 else { throw ICloudBackupError.forkDetected }
    guard let material = activeMaterials.first else {
        throw foundMaterial
            ? ICloudBackupError.automaticBackupPaused
            : ICloudBackupError.invalidRecoveryKey
    }
    return try vault.backUpToICloud(
        using: ICloudBackupCoordinator(store: cloud, material: material, stateStore: state),
        settings: ICloudBackupSettings(
            languageMode: preferences.languageMode,
            appearanceMode: preferences.appearanceMode,
            defaultTimedAllowanceMinutes: preferences.defaultTimedAllowanceMinutes,
            launchAtLogin: loginItem.isEnabled
        )
    )
}

private func automaticBackupIsEnabled(
    makeCloudStore: () throws -> ICloudBackupStore,
    materials: ICloudBackupMaterialStore,
    state: ICloudBackupLocalStateStore
) throws -> Bool {
    let manager = ICloudBackupNamespaceManager(
        cloud: try makeCloudStore(),
        materials: materials,
        state: state
    )
    for namespace in try manager.cloudNamespaces()
    where try materials.load(keyID: namespace) != nil {
        if try !state.isAutomaticBackupPaused(namespace: namespace) { return true }
    }
    return false
}

private func pendingAutomaticUploadExists(
    makeCloudStore: () throws -> ICloudBackupStore,
    materials: ICloudBackupMaterialStore,
    state: ICloudBackupLocalStateStore
) throws -> Bool {
    let manager = ICloudBackupNamespaceManager(
        cloud: try makeCloudStore(),
        materials: materials,
        state: state
    )
    for namespace in try manager.cloudNamespaces() {
        if try state.pendingUpload(namespace: namespace) != nil { return true }
    }
    return false
}
