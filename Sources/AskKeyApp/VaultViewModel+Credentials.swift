import SwiftUI
import AskKeyCore

extension VaultViewModel {
    @discardableResult
    func refreshCredentialSummary() -> Bool {
        var countRefreshed = true
        do { onboardingCredentialCount = try storedCredentialCountImpl() }
        catch {
            presentError(error)
            countRefreshed = false
        }
        let workspaceRefreshed = reloadCredentials()
        return countRefreshed && workspaceRefreshed
    }

    @discardableResult
    func reloadCredentialAccessRecords() -> Bool {
#if DEBUG
        if isVisualProof { return true }
#endif
        guard !isLocked, hasManagementSession else {
            credentialAccessRecords = []
            return false
        }
        do {
            credentialAccessRecords = try accessRecords.list()
            return true
        } catch {
            credentialAccessRecords = []
            presentError(error)
            return false
        }
    }

    func clearCredentialAccessRecords() async {
        guard !isLocked, hasManagementSession else {
            credentialAccessRecords = []
            presentError(VaultError.managementAuthenticationRequired)
            return
        }
        renewSession()
        renewManagementSession()
        let reason = "Clear Ask Key access records"
        let generation = managementAuthorizationGeneration
        let authenticator: ManagementAuthenticator
        if let authenticateCredentialAccessRecordClear {
            authenticator = await authenticateCredentialAccessRecordClear(reason)
        } else {
            guard let confirmed = await confirmDeviceOwner(reason: reason) else { return }
            authenticator = confirmed
        }
        guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return }
        clearCredentialAccessRecords(using: authenticator)
    }

    func clearCredentialAccessRecords(using authenticator: ManagementAuthenticator) {
        guard !isLocked, hasManagementSession else {
            credentialAccessRecords = []
            presentError(VaultError.managementAuthenticationRequired)
            return
        }
        do {
            try accessRecords.clear(authenticator)
            reloadCredentialAccessRecords()
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func reloadCredentials() -> Bool {
#if DEBUG
        if isVisualProof { return true }
#endif
        refreshAgentAccessPauseState()
        guard !isLocked, hasManagementSession else {
            credentials = []
            recycledCredentials = []
            storedCredentialGroups = []
            credentialAccessRecords = []
            return false
        }
        do {
            let snapshot = try loadCredentialWorkspaceImpl()
            credentials = snapshot.credentials
            recycledCredentials = snapshot.recycled
            onboardingCredentialCount = try storedCredentialCountImpl()
            storedCredentialGroups = snapshot.groups
            isAgentAccessPaused = try isAgentAccessPausedImpl()
            if snapshot.accessRecordWriteFailure {
                errorMessage = "Ask Key could not save an access record. Credential operations continue, and this warning will remain until recording succeeds."
            }
            return true
        } catch {
            credentials = []
            recycledCredentials = []
            storedCredentialGroups = []
            revealedCredential = nil
            presentError(error)
            return false
        }
    }

    func createCredentialGroup(_ name: String) {
        do {
            try credentialMutations.createCredentialGroup(name)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func deleteCredentialGroup(_ name: String) {
        do {
            try credentialMutations.deleteCredentialGroup(name)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func moveCredential(_ credential: ManagedTextCredential, toGroup groupName: String?) {
#if DEBUG
        if isVisualProof {
            guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else {
                presentError(VaultError.credentialNotFound(credential.id))
                return
            }
            credentials[index] = .visualProof(
                id: credential.id,
                name: credential.name,
                componentNames: credential.components.map(\.name),
                groupName: groupName,
                permission: credential.permission,
                deletedAt: credential.deletedAt
            )
            return
        }
#endif
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateCredentialGroup(credential.id, groupName)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func updateCredentialPermission(
        _ credential: ManagedTextCredential,
        permission: CredentialPermission
    ) {
#if DEBUG
        if isVisualProof {
            guard let index = credentials.firstIndex(where: { $0.id == credential.id }) else {
                presentError(VaultError.credentialNotFound(credential.id))
                return
            }
            credentials[index] = .visualProof(
                id: credential.id,
                name: credential.name,
                componentNames: credential.components.map(\.name),
                groupName: credential.groupName,
                permission: permission,
                deletedAt: credential.deletedAt
            )
            return
        }
#endif
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateCredentialPermission(credential.id, permission)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func updateCredentialMetadata(
        id: String,
        name: String,
        usageInstructions: String,
        groupName: String?,
        permission: CredentialPermission,
        expiresAt: Date?
    ) -> Bool {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateCredentialMetadata(
                id,
                name,
                usageInstructions,
                groupName,
                permission,
                expiresAt
            )
            reloadCredentials()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func restoreRecycledCredential(_ credential: ManagedTextCredential) {
#if DEBUG
        if isVisualProof {
            recycledCredentials.removeAll { $0.id == credential.id }
            credentials.append(.visualProof(
                id: credential.id,
                name: credential.name,
                componentNames: credential.components.map(\.name),
                groupName: credential.groupName,
                permission: credential.permission
            ))
            return
        }
#endif
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.restoreRecycled(credential.id)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func permanentlyDeleteRecycledCredential(_ credential: ManagedTextCredential) async {
        renewSession()
        renewManagementSession()
        guard let authenticator = await confirmDeviceOwner(
            reason: ManagementAuthenticationAction.permanentlyDelete.reasonKey
        ) else { return }
        do {
            try credentialMutations.permanentlyDeleteRecycled(credential.id, authenticator)
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func pauseAgentAccess() async {
        guard let authenticator = await confirmDeviceOwner(
            reason: CredentialManagementCopy.pauseReason
        ) else { return }
        do {
            try pauseAgentAccessImpl(authenticator)
            isAgentAccessPaused = true
        } catch {
            presentError(error)
            refreshAgentAccessPauseState()
        }
    }

    func resumeAgentAccess() async {
        guard let authenticator = await confirmDeviceOwner(
            reason: CredentialManagementCopy.resumeReason
        ) else { return }
        do {
            try resumeAgentAccessImpl(authenticator)
            isAgentAccessPaused = false
        } catch {
            presentError(error)
            refreshAgentAccessPauseState()
        }
    }

    @discardableResult
    func eraseLocalLibrary(confirmation: String) async -> Bool {
        await eraseLocalLibrary(confirmation: confirmation, deletingICloudWith: nil)
    }

    @discardableResult
    func eraseLocalLibrary(
        confirmation: String,
        deletingICloudWith recoveryKey: String?
    ) async -> Bool {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return false
        }
        renewSession()
        renewManagementSession()
        let reason = "Erase the local Ask Key vault"
        let generation = managementAuthorizationGeneration
        let authenticator: ManagementAuthenticator
        if let authenticateLocalErase {
            authenticator = await authenticateLocalErase(reason)
        } else {
            guard let confirmed = await confirmDeviceOwner(reason: reason) else { return false }
            authenticator = confirmed
        }
        guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return false }
        let cloudAuthenticator: ManagementAuthenticator?
        if recoveryKey != nil {
            cloudAuthenticator = await iCloudAuthenticator(reason: "Delete Ask Key iCloud backup")
            guard cloudAuthenticator != nil else { return false }
        } else {
            cloudAuthenticator = nil
        }
        guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return false }
        do {
            let language: LocalVaultEraseLanguage = AppLanguage.resolve(mode: languageMode)
                == "zh-Hans" ? .simplifiedChinese : .english
            try eraseLocalLibraryImpl(confirmation, language, authenticator)
            if let recoveryKey, let cloudAuthenticator {
                do {
                    try deleteICloudBackupImpl(recoveryKey, cloudAuthenticator)
                } catch {
                    setICloudBackupStatus(iCloudBackupMessage(for: error))
                }
            }
            lock()
            isAgentAccessPaused = true
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private var canRecoverIntoEmptyLibrary: Bool {
        !migrationRequired && (try? storedCredentialCountImpl()) == 0
    }

    func inspectICloudBackup(recoveryKey: String) -> [ICloudBackupGeneration] {
        guard (!isLocked && hasManagementSession) || canRecoverIntoEmptyLibrary else {
            presentError(VaultError.managementAuthenticationRequired)
            return []
        }
        do {
            let generations = try inspectICloudBackupImpl(recoveryKey)
            if generations.isEmpty {
                setICloudBackupStatus("No recoverable backup was found.")
            } else {
                setICloudBackupStatus("Found %lld recoverable backups.", count: generations.count)
            }
            return generations
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return []
        }
    }

    func listICloudBackupConflicts(recoveryKey: String) -> [String] {
        guard !isLocked, hasManagementSession else { return [] }
        do {
            return try listICloudBackupConflictsImpl(recoveryKey)
        } catch {
            presentError(error)
            return []
        }
    }

    func restoreICloudBackup(
        recoveryKey: String,
        generationID: String
    ) async -> ICloudBackupGeneration? {
        let requiresEmptyLibrary = isLocked || !hasManagementSession
        guard !requiresEmptyLibrary || canRecoverIntoEmptyLibrary else {
            presentError(VaultError.managementAuthenticationRequired)
            return nil
        }
        let reason = "Restore Ask Key encrypted backup"
        guard let authenticator = await iCloudAuthenticator(reason: reason) else { return nil }
        do {
            // Recheck after authentication: the local library may have changed while the prompt was open.
            if requiresEmptyLibrary && !canRecoverIntoEmptyLibrary {
                throw VaultError.managementAuthenticationRequired
            }
            if isLocked || !hasManagementSession {
                if isLocked {
                    try unlockVaultImpl()
                    isLocked = false
                }
                try beginManagementSessionImpl(authenticator)
                hasManagementSession = true
                showsLockedWorkbench = false
            }
            let generation = try restoreICloudBackupImpl(recoveryKey, generationID, authenticator)
            // Core has committed the restored library. A later UI read failure must
            // not strand that existing library behind first-run creation on relaunch.
            hasCompletedOnboarding = true
            adoptRestoredPreferences()
            let summaryRefreshed = refreshCredentialSummary()
            let recordsRefreshed = reloadCredentialAccessRecords()
            renewManagementSession()
            guard summaryRefreshed && recordsRefreshed else {
                setICloudBackupStatus(
                    "The backup was restored, but the local view could not refresh. Restart the app to check it; do not restore again."
                )
                return nil
            }
            setICloudBackupStatus("Backup restored. The local credential list is up to date.")
            return generation
        } catch {
            // Applying settings may have enabled authentication before a later
            // setting failed. Keep the current UI and machine on that safe value.
            adoptRestoredPreferences()
            refreshAgentAccessPauseState()
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return nil
        }
    }

    func listICloudBackupNamespaces() -> [String] {
        guard !isLocked, hasManagementSession else { return [] }
        do {
            return try listICloudBackupNamespacesImpl()
        } catch {
            presentError(error)
            return []
        }
    }

    func backUpNow() -> ICloudBackupGeneration? {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return nil
        }
        do {
            return try immediateICloudBackupImpl()
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return nil
        }
    }

    @discardableResult
    func refreshICloudBackupEnabled(preservingStatus: Bool = false) -> Bool {
#if DEBUG
        if isVisualProof { return true }
#endif
        let operationStatus = preservingStatus ? iCloudBackupStatusCopy : nil
        defer {
            if let operationStatus { setICloudBackupStatus(operationStatus) }
        }
        do {
            iCloudBackupEnabled = try iCloudBackupEnabledImpl()
            setICloudBackupStatus(nil)
            return true
        } catch {
            iCloudBackupEnabled = false
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return false
        }
    }

    func setICloudBackupEnabled(_ enabled: Bool) {
        do {
            iCloudBackupEnabled = try setICloudBackupEnabledImpl(enabled)
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
        }
    }

    func createICloudBackupNamespace() async -> String? {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return nil
        }
        let reason = "Create a new Ask Key backup namespace"
        guard let authenticator = await iCloudAuthenticator(reason: reason) else { return nil }
        do {
            return try createICloudBackupNamespaceImpl(authenticator)
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return nil
        }
    }

    func activateICloudBackupNamespace(recoveryKey: String) async -> ICloudBackupGeneration? {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return nil
        }
        let reason = "Start Ask Key backup with the saved recovery key"
        guard let authenticator = await iCloudAuthenticator(reason: reason) else { return nil }
        do {
            return try activateICloudBackupNamespaceImpl(recoveryKey, authenticator)
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return nil
        }
    }

    func takeOwnershipOfICloudBackup(recoveryKey: String, generationID: String) async -> Bool {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return false
        }
        let reason = "Take ownership of Ask Key iCloud backup"
        guard let authenticator = await iCloudAuthenticator(reason: reason) else { return false }
        do {
            try takeOwnershipOfICloudBackupImpl(recoveryKey, generationID, authenticator)
            guard refreshICloudBackupEnabled() else {
                setICloudBackupStatus(
                    "This Mac owns future backups, but automatic backup status could not be confirmed. Check the backup settings before continuing."
                )
                return false
            }
            setICloudBackupStatus(
                iCloudBackupEnabled
                    ? "This Mac owns future backups. Automatic backup has resumed."
                    : "This Mac owns future backups. Automatic backup is currently off."
            )
            return true
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return false
        }
    }

    func deleteICloudBackup(recoveryKey: String) async -> Bool {
        guard !isLocked, hasManagementSession else {
            presentError(VaultError.managementAuthenticationRequired)
            return false
        }
        let reason = "Delete Ask Key iCloud backup"
        guard let authenticator = await iCloudAuthenticator(reason: reason) else { return false }
        do {
            try deleteICloudBackupImpl(recoveryKey, authenticator)
            return true
        } catch {
            setICloudBackupStatus(iCloudBackupMessage(for: error))
            return false
        }
    }

    func addTextCredential(_ input: TextCredentialInput) {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.createText(input)
            onboardingCredentialCount = try storedCredentialCountImpl()
            revealedCredential = nil
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func addBundleCredential(_ input: BundleCredentialInput) -> Bool {
#if DEBUG
        if isVisualProof {
            credentials.append(.visualProof(
                id: UUID().uuidString,
                name: input.name,
                componentNames: input.components.map(\.name),
                groupName: input.groupName,
                permission: input.permission
            ))
            return true
        }
#endif
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.createBundle(input)
            onboardingCredentialCount = try storedCredentialCountImpl()
            revealedCredential = nil
            reloadCredentials()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    @discardableResult
    func updateBundleCredential(id: String, _ input: BundleCredentialInput) -> Bool {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateBundle(id, input)
            revealedCredential = nil
            reloadCredentials()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func replaceImportedBundleCredential(
        id: String,
        components: [CredentialComponentInput]
    ) async -> Bool {
        renewSession()
        renewManagementSession()
        guard let authenticator = await confirmDeviceOwner(
            reason: ManagementAuthenticationAction.replaceImportedCredential.reasonKey
        ) else { return false }
        do {
            try credentialMutations.replaceImportedBundle(id, components, authenticator)
            revealedCredential = nil
            reloadCredentials()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func updateTextCredential(id: String, _ input: TextCredentialInput) {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateText(id, input)
            revealedCredential = nil
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func addFileCredential(_ input: FileCredentialInput) {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.createFile(input)
            onboardingCredentialCount = try storedCredentialCountImpl()
            revealedCredential = nil
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func updateFileCredential(id: String, _ input: FileCredentialInput) {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.updateFile(id, input)
            revealedCredential = nil
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func deleteTextCredential(_ credential: ManagedTextCredential) {
#if DEBUG
        if isVisualProof {
            credentials.removeAll { $0.id == credential.id }
            recycledCredentials.insert(.visualProof(
                id: credential.id,
                name: credential.name,
                componentNames: credential.components.map(\.name),
                groupName: credential.groupName,
                permission: credential.permission,
                deletedAt: Date()
            ), at: 0)
            return
        }
#endif
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.deleteText(credential.id)
            if revealedCredential?.id == credential.id {
                revealedCredential = nil
            }
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    func revealTextCredential(_ credential: ManagedTextCredential) async -> ManagedTextCredential? {
        renewSession()
        renewManagementSession()
        guard let authenticator = await confirmDeviceOwner(
            reason: CredentialManagementCopy.revealReason
        ) else { return nil }
        do {
            let revealed = try credentialMutations.revealText(credential.id, authenticator)
            revealedCredential = revealed
            return revealed
        } catch {
            presentError(error)
            return nil
        }
    }

    func copyTextCredentialValue(_ credential: ManagedTextCredential) {
        Task { @MainActor in
            guard let revealed = await revealTextCredential(credential) else { return }
            if credential.payloadKind == .file {
                guard let bytes = revealed.fileBytes,
                      let value = String(data: bytes, encoding: .utf8) else { return }
                clipboard.copy(value, clearAfter: clipboardClearSeconds)
                return
            }
            guard let value = revealed.value else { return }
            clipboard.copy(value, clearAfter: clipboardClearSeconds)
        }
    }

    func copyCredentialComponent(
        _ credential: ManagedTextCredential,
        componentName: String
    ) {
        Task { @MainActor in
            guard let revealed = await revealTextCredential(credential),
                  let component = revealed.components.first(where: { $0.name == componentName }) else {
                return
            }
            switch component.value {
            case .text(let value):
                clipboard.copy(value, clearAfter: clipboardClearSeconds)
            case .file(_, let bytes):
                guard let value = String(data: bytes, encoding: .utf8) else { return }
                clipboard.copy(value, clearAfter: clipboardClearSeconds)
            case nil:
                return
            }
        }
    }

    var credentialGroups: [String] {
        Array(Set(storedCredentialGroups + credentials.compactMap(\.groupName))).sorted()
    }

    private func iCloudBackupMessage(for error: Error) -> String {
        guard let error = error as? ICloudBackupError else {
            return error.localizedDescription
        }
        switch error {
        case .invalidRecoveryKey: return "The recovery key is invalid. Check it and try again."
        case .randomGenerationFailed: return "Ask Key could not securely generate a recovery key. Try again."
        case .noValidGeneration: return "No complete, verifiable backup was found."
        case .invalidGeneration: return "The backup is incomplete or damaged."
        case .automaticBackupPaused: return "Automatic backup is paused until the backup conflict is resolved."
        case .conflictCopy, .forkDetected: return "Multiple backup versions were found. Choose one to restore."
        case .differentWriter: return "Another device wrote this backup. Confirm takeover first."
        case .propagationPending: return "iCloud is still syncing. Try again shortly."
        case .containerUnavailable: return "iCloud Backup is unavailable. Check iCloud and try again."
        case .capabilityUnavailable: return "This development or ad-hoc build does not have Ask Key's own iCloud capability. Official releases require Ask Key's container, entitlement, and signing materials."
        case .invalidSnapshot: return "This backup cannot be restored safely."
        case .authenticationRequired: return "System authentication is required."
        case .keyMaterialReadFailed: return "Ask Key could not read the local backup key. Check Keychain access."
        case .keyMaterialWriteFailed: return "Ask Key could not save the local backup key. Check Keychain access."
        case .cleanupFailed: return "The backup operation could not finish cleanup. Existing backups were preserved."
        case .invalidCleanupState: return "Backup cleanup state is invalid, so Ask Key stopped safely."
        case .invalidPendingUpload: return "The interrupted backup could not be verified. Existing backups were preserved."
        }
    }

    private func iCloudAuthenticator(reason: String) async -> ManagementAuthenticator? {
        if let authenticateICloudLifecycle {
            let generation = managementAuthorizationGeneration
            let result = await authenticateICloudLifecycle(reason)
            guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return nil }
            return result
        }
        return await confirmDeviceOwner(reason: reason)
    }

    func confirmDeviceOwner(reason: String) async -> ManagementAuthenticator? {
        guard !Task.isCancelled else { return nil }
        let generation = managementAuthorizationGeneration
        let presentation = ManagementAuthenticationPresentation.current(reason: reason)
        if let authenticateDeviceOwner {
            let result = await authenticateDeviceOwner(presentation)
            guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return nil }
            return result
        }
        let outcome = await ManagementAuthenticationRunner.shared.authenticate(
            presentation: presentation
        )
        guard generation == managementAuthorizationGeneration, !Task.isCancelled else { return nil }
        switch outcome {
        case .authenticated:
            return .allow
        case .cancelled:
            return nil
        case .failed:
            errorMessage = appLocalized("System authentication failed.")
            return nil
        }
    }
}
