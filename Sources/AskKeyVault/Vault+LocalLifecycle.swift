import Foundation

extension Vault {
    public func eraseLocalLibrary(
        confirmation: String,
        language: LocalVaultEraseLanguage,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try makeLocalEraseCoordinator().erase(
            confirmation: confirmation,
            language: language,
            using: authenticator
        )
    }

    public func recoverInterruptedLocalErase() throws {
        try makeLocalEraseCoordinator().recoverIfNeeded()
    }

    func makeLocalEraseCoordinator(
        journal: LocalVaultEraseJournalStore? = nil,
        deleteEncryptedData: (@Sendable () throws -> Void)? = nil,
        deleteLocalKey: (@Sendable () throws -> Void)? = nil
    ) -> LocalVaultEraseCoordinator {
        LocalVaultEraseCoordinator(
            journal: journal ?? FileLocalVaultEraseJournalStore(
                url: VaultConfiguration.localEraseJournalURL
            ),
            actions: .init(
                quiesceOperations: { [weak self] in
                    guard let self else { throw VaultError.databaseError("Vault lifecycle unavailable.") }
                    try self.quiesceForLocalErase()
                },
                cleanupDeliveries: { [weak self] in
                    guard let self else { throw VaultError.databaseError("Vault lifecycle unavailable.") }
                    self.cleanupRuntimeFileDeliveries()
                    guard !self.hasRuntimeFileCleanupFailures else {
                        throw VaultError.databaseError(
                            "Temporary credential cleanup must finish before local erase."
                        )
                    }
                },
                deleteEncryptedData: deleteEncryptedData ?? { [weak self] in
                    guard let self else { throw VaultError.databaseError("Vault lifecycle unavailable.") }
                    try self.deleteEncryptedLocalData()
                },
                deleteLocalKey: deleteLocalKey ?? { [weak self] in
                    guard let self else { throw VaultError.databaseError("Vault lifecycle unavailable.") }
                    try self.deleteAllLocalKeyMaterial()
                }
            )
        )
    }

    private func quiesceForLocalErase() throws {
        _ = try agentAccessGate.beginExclusiveChange()
        brokerRequests.pauseAndCancelAll()
        approvalRequests.pauseAndCancelAll()
        agentAccessGate.endExclusiveChange(paused: true)
    }

    private func deleteEncryptedLocalData() throws {
        try closeStoreForLocalErase()
        let directory = VaultConfiguration.applicationSupportDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func deleteAllLocalKeyMaterial() throws {
        try deleteAllLocalVaultKeys()
        finishLocalErase()
    }
}
