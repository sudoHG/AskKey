import CryptoKit
import Foundation
import GRDB
import Security
import AskKeyBroker

public final class Vault {
    private static let sharedLock = NSLock()
    private static var sharedInstance: Vault?
    private static var sharedWasResolved = false

    public static var shared: Vault {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if sharedInstance == nil { sharedInstance = Vault() }
        sharedWasResolved = true
        return sharedInstance!
    }

    /// An executable may supply its store once, before any shared consumers start.
    package static func configureShared(_ vault: Vault) {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        precondition(!sharedWasResolved && sharedInstance == nil)
        sharedInstance = vault
    }
    private static let defaultFileDeliveryManager = FileDeliveryManagerRegistry()
    public let brokerRequests = BrokerRequestRegistry()
    public let approvalRequests: BrokerApprovalStateMachine
    let agentTextWrites = FrozenAgentTextWriteRegistry()
    let agentOrganizations = FrozenAgentOrganizationRegistry()

    // The daemon serves on background threads while the app uses Vault.shared on
    // the main thread (ADR 0014), so the shared key/store are lock-guarded. The
    // lock is never held across a Keychain or DB call (GRDB serializes the DB
    // itself) and never re-entered, so it can't deadlock.
    public static let managementSessionIdleLimit: TimeInterval = 5 * 60

    private let stateLock = NSLock()
    private let lifecycleLock = NSRecursiveLock()
    let agentAccessGate = AgentAccessGate()
    let fileDeliveryManager: FileDeliveryManagerRegistry
    private let clock: () -> Date
    private var _key: SymmetricKey?
    private var _store: VaultStore?
    private var _openedLibraryURL: URL?
    private var _managementSessionExpiresAt: Date?
    private var _accessRecordWriteFailed = false
    private var _agentAccessPolicyState: AgentAccessPolicyState?
    private var _policyKeyStore: AppKeyStore?
    private var _agentAccessPolicyLatches = AgentAccessPolicyLatches()
    let agentAccessPolicyOwnership = AgentAccessPolicyOwnership()
    private let pathsOverride: VaultBootstrapPaths?
    private let keyStoreOverride: AppKeyStore?
    var legacyAgentAccessRowsRemoved = false

    func notifySnapshotRelevantChange() {
        NotificationCenter.default.post(name: .askKeyCredentialSnapshotDidChange, object: nil)
    }

    func finishCredentialChange(wasPaused: Bool, snapshotChanged: Bool) {
        agentAccessGate.endExclusiveChange(paused: wasPaused,
                                          retryPolicyRead: (try? savedAgentAccessPolicyState().readUnavailable) == true)
        if snapshotChanged { notifySnapshotRelevantChange() }
    }

    private var key: SymmetricKey? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _key }
        set {
            stateLock.lock()
            _key = newValue
            _store?.bindCredentialAuthenticationKey(newValue)
            stateLock.unlock()
        }
    }

    var store: VaultStore {
        get throws {
            stateLock.lock()
            defer { stateLock.unlock() }
            if let _store { return _store }
            // Store creation belongs exclusively to the verified bootstrap.
            // Metadata queries before unlock must never create/upgrade vault.db.
            throw VaultError.vaultLocked
        }
    }

    private init() {
        approvalRequests = BrokerApprovalStateMachine()
        fileDeliveryManager = Self.defaultFileDeliveryManager
        clock = Date.init
        pathsOverride = nil
        keyStoreOverride = nil
        configureAgentTextWriteCleanup()
    }

    /// Dependency injection for an explicitly owned library and key store.
    /// Opening still uses the production bootstrap and adoption path.
    init(
        paths: VaultBootstrapPaths,
        keyStore: AppKeyStore,
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine(),
        fileDeliveryManager: FileDeliveryManager? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        pathsOverride = paths
        keyStoreOverride = keyStore
        self.approvalRequests = approvalRequests
        clock = now
        if let fileDeliveryManager {
            self.fileDeliveryManager = FileDeliveryManagerRegistry(manager: fileDeliveryManager)
        } else {
            self.fileDeliveryManager = Self.defaultFileDeliveryManager
        }
        agentAccessPolicyOwnership.set(true)
        configureAgentTextWriteCleanup()
    }

    /// Test seam: build a Vault over an explicit store (and optional key) so
    /// credential logic can be exercised without the real vault file or
    /// Keychain. Not used in production code.
    package init(
        store: VaultStore,
        key: SymmetricKey? = nil,
        policyStore: AppKeyStore,
        now: @escaping () -> Date = Date.init,
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine(),
        fileDeliveryManager: FileDeliveryManager? = nil
    ) {
        self._store = store
        self._policyKeyStore = policyStore
        pathsOverride = nil
        keyStoreOverride = policyStore
        self.clock = now
        self.approvalRequests = approvalRequests
        if let fileDeliveryManager {
            self.fileDeliveryManager = FileDeliveryManagerRegistry(manager: fileDeliveryManager)
        } else {
            let testRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKeyTests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.fileDeliveryManager = FileDeliveryManagerRegistry(
                retryDelay: 1,
                factory: { try FileDeliveryManager(rootURL: testRoot) }
            )
        }
        agentAccessPolicyOwnership.set(true)
        self.key = key
        if let key {
            do {
                try adoptBootstrappedLibrary((store, key, false), keyStore: policyStore)
            } catch {
                // Adoption already quiesced the gate and deliveries.
            }
        }
        configureAgentTextWriteCleanup()
    }

    package func agentAccessPolicyState() throws -> AgentAccessPolicyState {
        let state = try savedAgentAccessPolicyState()
        return .init(policy: state.policy, needsRecovery: state.needsRecovery,
                     isPaused: try agentAccessGate.isPaused(), pauseNotPersisted: state.pauseNotPersisted,
                     saveFailure: state.saveFailure, keychainConflict: state.keychainConflict,
                     readUnavailable: state.readUnavailable, hasVerifiedPolicy: state.hasVerifiedPolicy,
                     readFailure: state.readFailure)
    }

    func savedAgentAccessPolicyState() throws -> AgentAccessPolicyState {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let state = _agentAccessPolicyState else { throw VaultError.vaultLocked }
        return state
    }

    func setAgentAccessPolicyState(_ state: AgentAccessPolicyState) {
        stateLock.lock()
        _agentAccessPolicyState = state
        stateLock.unlock()
    }

    func agentAccessPolicyLatches() -> AgentAccessPolicyLatches {
        stateLock.lock(); defer { stateLock.unlock() }
        return _agentAccessPolicyLatches
    }

    func changeAgentAccessPolicyLatches(_ change: (inout AgentAccessPolicyLatches) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        change(&_agentAccessPolicyLatches)
    }

    func policyKeyStore() throws -> AppKeyStore {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let store = _policyKeyStore else { throw VaultError.vaultLocked }
        return store
    }

    public func validateStoreAvailability() throws {
        _ = try bootstrapState()
    }

    public func bootstrapState() throws -> VaultBootstrapState {
        try VaultConfiguration.validateRuntimeIsolation()
        return try VaultBootstrap.state(paths: bootstrapPaths)
    }

    func credentialCountForBootstrap() throws -> Int {
        stateLock.lock()
        let current = _store
        stateLock.unlock()
        if let current {
            return try current.db.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials") ?? 0
            }
        }
        try VaultConfiguration.validateRuntimeIsolation()
        return try VaultBootstrap.credentialCount(paths: bootstrapPaths)
    }

    private func configureAgentTextWriteCleanup() {
        approvalRequests.configureOperationStateChanged { [weak self] operationID, request, state in
            guard let self else { return }
            if state != .pending, state != .approved {
                if request?.operation == .organize {
                    self.agentOrganizations.remove(operationID: operationID)
                    if let request, state == .denied || state == .cancelled || state == .expired {
                        self.recordAgentOrganizationAccess(request, result: state == .expired ? .expired : .denied)
                    }
                    return
                }
                let frozen = self.agentTextWrites.entry(operationID: operationID)
                self.agentTextWrites.remove(operationID: operationID)
                if let approvalRequest = request ?? frozen?.approvalRequest,
                   state == .denied || state == .cancelled || state == .expired {
                    let operation: CredentialAccessEvent.Operation
                    switch approvalRequest.operation {
                    case .create: operation = .create
                    case .modify: operation = .modify
                    case .organize: operation = .modify
                    case .delete: operation = .delete
                    case .read: operation = .runtimeRead
                    }
                    self.recordCredentialAccess(.init(
                        timestamp: self.currentDate,
                        credentialID: approvalRequest.credentialID,
                        operation: operation,
                        result: state == .expired ? .expired : .denied,
                        callerHint: approvalRequest.callerName,
                        declaredPurpose: approvalRequest.callerPurpose,
                        executableBasename: operation == .runtimeRead
                            ? approvalRequest.display?.executableBasename : nil
                    ))
                }
            }
        }
    }

    // MARK: - Setup

    /// Loads only the App-owned current format for background Agent work.
    /// Human management remains independently locked.
    public func prepareAgentRuntime() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try VaultConfiguration.validateRuntimeIsolation()
        try prepareAgentRuntime(paths: bootstrapPaths, keyStore: { try self.appKeyStore() })
    }

    // Explicit synthetic paths/key store keep startup tests off the real vault.
    func prepareAgentRuntime(paths: VaultBootstrapPaths, keyStore: () throws -> AppKeyStore) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.lock()
        let alreadyLoaded = _store != nil && _key != nil
        stateLock.unlock()
        if alreadyLoaded { return }

        try openBootstrappedLibrary(paths: paths, keyStore: keyStore)
    }

    public func unlock() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        try VaultConfiguration.validateRuntimeIsolation()
        try recoverInterruptedLocalErase()
        try openBootstrappedLibrary()
    }

    public func lock() {
        do {
            _ = try agentAccessGate.beginExclusiveChange()
            quiesceAgentAccess()
            key = nil
            endManagementSession()
            agentAccessGate.endExclusiveChange(paused: true)
        } catch {
            key = nil
            endManagementSession()
        }
    }

    public var isLocked: Bool { key == nil }

    public var hasActiveManagementSession: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isManagementSessionValidLocked()
    }

    public func beginManagementSession(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        stateLock.lock()
        _managementSessionExpiresAt = clock().addingTimeInterval(Self.managementSessionIdleLimit)
        stateLock.unlock()
    }

    public func beginOnboardingManagementSession() throws {
        try beginOnboardingCreation()
    }

    /// Validates the first-creation path without granting list/reveal/settings
    /// access. Creation checks emptiness again under the mutation gate.
    public func beginOnboardingCreation() throws {
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer {
            agentAccessGate.endExclusiveChange(paused: wasPaused,
                                              retryPolicyRead: (try? savedAgentAccessPolicyState().readUnavailable) == true)
        }
        guard try store.fetchAllCredentials().isEmpty,
              try store.fetchRecycledCredentials().isEmpty else {
            throw VaultError.managementAuthenticationRequired
        }
    }

    func performCredentialCreation<T>(
        using authenticator: ManagementAuthenticator,
        _ create: () throws -> T
    ) throws -> T {
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var changed = false
        defer { finishCredentialChange(wasPaused: wasPaused, snapshotChanged: changed) }
        let isFirst = try store.fetchAllCredentials().isEmpty && store.fetchRecycledCredentials().isEmpty
        if !isFirst {
            try requireManagementSession()
            try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        }
        let created = try create()
        changed = true
        return created
    }

    public func endManagementSession() {
        stateLock.lock()
        _managementSessionExpiresAt = nil
        stateLock.unlock()
    }

    func requireManagementSession() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isManagementSessionValidLocked() else {
            _managementSessionExpiresAt = nil
            throw VaultError.managementAuthenticationRequired
        }
        _managementSessionExpiresAt = clock().addingTimeInterval(Self.managementSessionIdleLimit)
    }

    private func isManagementSessionValidLocked() -> Bool {
        guard let expires = _managementSessionExpiresAt else { return false }
        return clock() < expires
    }

    var currentDate: Date { clock() }

    func setAccessRecordWriteFailed(_ failed: Bool) {
        stateLock.lock()
        _accessRecordWriteFailed = failed
        stateLock.unlock()
    }

    var accessRecordWriteFailed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _accessRecordWriteFailed
    }

    func authorizeManagement(_ authenticator: ManagementAuthenticator, reason: String) throws {
        guard authenticator.confirm(reason: reason) else {
            throw VaultError.managementAuthenticationRequired
        }
    }

    // MARK: - Environment variable names

    /// Credential environment-variable mappings must use POSIX shell identifiers,
    /// so a mapped name is always a valid, unambiguous key in the environment a
    /// credential is delivered into. `CredentialFieldValidation` applies this rule
    /// to every credential and component mapping before it is stored.
    static let secretNamePattern = "^[A-Za-z_][A-Za-z0-9_]*$"

    static func validateSecretName(_ name: String) throws {
        guard name.utf8.count <= BrokerLimits.maximumFieldBytes else {
            throw VaultError.invalidSecretName(name)
        }
        let range = NSRange(name.startIndex..., in: name)
        guard let regex = try? NSRegularExpression(pattern: secretNamePattern),
              regex.firstMatch(in: name, range: range) != nil else {
            throw VaultError.invalidSecretName(name)
        }
    }

    // MARK: - Helpers

    func requireKey() throws -> SymmetricKey {
        guard let key else {
            throw VaultError.vaultLocked
        }
        return key
    }

    private var bootstrapPaths: VaultBootstrapPaths {
        pathsOverride ?? .init(directory: VaultConfiguration.applicationSupportDirectory,
              durabilityRoot: VaultConfiguration.bootstrapDurabilityRoot)
    }

    var libraryDirectory: URL { bootstrapPaths.directory }

    var localEraseJournalURL: URL {
        guard let pathsOverride else { return VaultConfiguration.localEraseJournalURL }
        return pathsOverride.directory.deletingLastPathComponent()
            .appendingPathComponent("\(pathsOverride.directory.lastPathComponent)-erase.journal")
    }

    private func openBootstrappedLibrary() throws {
        try openBootstrappedLibrary(paths: bootstrapPaths, keyStore: appKeyStore)
    }

    private func openBootstrappedLibrary(paths: VaultBootstrapPaths, keyStore: () throws -> AppKeyStore) throws {
        let keys: AppKeyStore
        let opened: (store: VaultStore, key: SymmetricKey, created: Bool)
        do {
            keys = try keyStore()
            let databaseURL = paths.currentDatabase.standardizedFileURL.resolvingSymlinksInPath()
            stateLock.lock()
            let hasOpenLibrary = _store != nil && _openedLibraryURL == databaseURL
            stateLock.unlock()
            opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, allowsCreation: !hasOpenLibrary)
        } catch {
            _ = try agentAccessGate.beginExclusiveChange()
            applyAgentAccessPolicy(.failClosed, needsRecovery: !((error as? AgentAccessPolicyError)?.isOwnershipFailure ?? false),
                                   keychainConflict: (error as? AppKeyStoreError)?.conflictingItemKind)
            key = nil
            endManagementSession()
            agentAccessGate.endExclusiveChange(paused: true)
            throw error
        }
        try adoptBootstrappedLibrary(opened, keyStore: keys)
        stateLock.lock()
        _openedLibraryURL = paths.currentDatabase.standardizedFileURL.resolvingSymlinksInPath()
        stateLock.unlock()
    }

    private func adoptBootstrappedLibrary(
        _ opened: (store: VaultStore, key: SymmetricKey, created: Bool), keyStore: AppKeyStore
    ) throws {
        _ = try agentAccessGate.beginExclusiveChange(reopening: true)
        var paused = true
        defer {
            let state = try? savedAgentAccessPolicyState()
            agentAccessGate.endExclusiveChange(paused: paused,
                                              retryPolicyRead: state?.readUnavailable == true && state?.policy.paused == false)
        }
        do {
            let loaded = try loadAgentAccessPolicy(key: opened.key, keyStore: keyStore, created: opened.created)
            let state = resolveAgentAccessPolicyLatches(loaded, key: opened.key, keyStore: keyStore)
            applyAgentAccessPolicy(state.policy, needsRecovery: state.needsRecovery,
                                   keychainConflict: state.keychainConflict, readUnavailable: state.readUnavailable,
                                   hasVerifiedPolicy: state.hasVerifiedPolicy,
                                   readFailure: state.readFailure,
                                   adoptingPersisted: true)
            stateLock.lock()
            let oldStore = _store
            stateLock.unlock()
            if let oldStore, oldStore !== opened.store { try oldStore.close() }
            stateLock.lock()
            _key = opened.key
            _store = opened.store
            _policyKeyStore = keyStore
            stateLock.unlock()
            if !state.needsRecovery { removeLegacyAgentAccessRows(from: opened.store) }
            paused = state.isPaused
        } catch {
            applyAgentAccessPolicy(.failClosed, needsRecovery: !((error as? AgentAccessPolicyError)?.isOwnershipFailure ?? false),
                                   keychainConflict: (error as? AppKeyStoreError)?.conflictingItemKind)
            key = nil
            endManagementSession()
            try? opened.store.close()
            throw error
        }
    }

    func appKeyStore() throws -> AppKeyStore {
        if let keyStoreOverride { return keyStoreOverride }
        return try makeAppKeyStore(
            legacyService: VaultConfiguration.keychainService,
            pendingService: VaultConfiguration.pendingAppKeychainService,
            appService: VaultConfiguration.appKeychainService
        )
    }

    func deleteAllLocalVaultKeys() throws {
        let stores: [AppKeyStore]
        if let keyStoreOverride {
            stores = [keyStoreOverride]
        } else {
            stores = [try appKeyStore(), try makeAppKeyStore(
                legacyService: VaultConfiguration.keychainService,
                pendingService: VaultConfiguration.previousAppKeychainService + ".migration",
                appService: VaultConfiguration.previousAppKeychainService
            )]
        }
        for store in stores {
            try store.deleteAgentAccessPolicy()
            try store.deleteLegacyKey()
            try store.deletePendingKey()
            try store.deleteAppKey()
        }
    }

    private func makeAppKeyStore(
        legacyService: String, pendingService: String, appService: String
    ) throws -> AppKeyStore {
        try VaultConfiguration.validateRuntimeIsolation()
        #if DEBUG
        if let directory = VaultConfiguration.debugRunDirectory {
            return try IsolatedAppKeyStore(
                directory: directory, legacyService: legacyService,
                pendingService: pendingService, appService: appService
            )
        }
        #endif
        guard let executableURL = Bundle.main.executableURL else {
            throw AppKeyStoreError.securityFailure(errSecParam)
        }
        return AppBoundKeyStore(
            legacyService: legacyService,
            pendingService: pendingService,
            appService: appService,
            trustedApplicationURL: executableURL
        )
    }

    func closeStoreForLocalErase() throws {
        stateLock.lock()
        let current = _store
        stateLock.unlock()
        try current?.close()
        stateLock.lock()
        if _store === current { _store = nil; _openedLibraryURL = nil }
        stateLock.unlock()
    }

    func finishLocalErase() {
        stateLock.lock()
        _key = nil
        _store?.bindCredentialAuthenticationKey(nil)
        _store = nil
        _openedLibraryURL = nil
        _managementSessionExpiresAt = nil
        _agentAccessPolicyState = nil
        _policyKeyStore = nil
        _agentAccessPolicyLatches = .init()
        stateLock.unlock()
    }
}
