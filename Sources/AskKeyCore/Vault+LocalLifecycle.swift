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
        try Self.removeEncryptedLocalData(in: VaultConfiguration.applicationSupportDirectory)
    }

    /// Erase only local vault/runtime artifacts. Unrelated historical files are
    /// left in place without reading, rewriting or migrating their contents.
    static func removeEncryptedLocalData(in directory: URL) throws {
        let paths = VaultBootstrapPaths(directory: directory)
        let databases = [paths.legacyDatabase, paths.previousDatabase, paths.currentDatabase]
        var artifacts = databases + [paths.previousJournal, paths.currentJournal]
        for database in databases {
            let pending = database.appendingPathExtension("pending")
            artifacts.append(pending)
            for suffix in ["-wal", "-shm", "-journal"] {
                artifacts.append(URL(fileURLWithPath: database.path + suffix))
                artifacts.append(URL(fileURLWithPath: pending.path + suffix))
            }
        }
        artifacts.append(directory.appendingPathComponent("daemon.sock"))
        artifacts.append(directory.appendingPathComponent("file-write-staging", isDirectory: true))
        for artifact in artifacts {
            do {
                try FileManager.default.removeItem(at: artifact)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    private func deleteAllLocalKeyMaterial() throws {
        try deleteAllLocalVaultKeys()
        finishLocalErase()
    }
}
