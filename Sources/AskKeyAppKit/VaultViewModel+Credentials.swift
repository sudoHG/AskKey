import SwiftUI
import AskKeyVault

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
        do {
            let language: LocalVaultEraseLanguage = AppLanguage.resolve(mode: languageMode)
                == "zh-Hans" ? .simplifiedChinese : .english
            try eraseLocalLibraryImpl(confirmation, language, authenticator)
            lock()
            isAgentAccessPaused = true
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func addTextCredential(_ input: TextCredentialInput) {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.createText(input)
            recordOnboardingSave(name: input.name, permission: input.permission)
            onboardingCredentialCount = try storedCredentialCountImpl()
            revealedCredential = nil
            reloadCredentials()
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func addBundleCredential(_ input: BundleCredentialInput) -> Bool {
        renewSession()
        renewManagementSession()
        do {
            try credentialMutations.createBundle(input)
            recordOnboardingSave(name: input.name, permission: input.permission)
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
            recordOnboardingSave(name: input.name, permission: input.permission)
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
