import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum MigrationJournalState: String, Codable, Equatable, Sendable {
    case prepared
    case dbPromoted
    case keyPromoted
    case oldRevoked
    case complete
}

enum MigrationKeyStoreError: Error, Equatable {
    case missingLegacyKey
    case missingPendingKey
    case missingAppKey
    case securityFailure(OSStatus)
    case conflictingKey
}

final class AppBoundMigrationKeyStore: MigrationKeyStore {
    private static let account = "vault-key"

    private let legacyService: String
    private let pendingService: String
    private let appService: String
    private let trustedApplicationURL: URL

    init(
        legacyService: String,
        pendingService: String,
        appService: String,
        trustedApplicationURL: URL
    ) {
        self.legacyService = legacyService
        self.pendingService = pendingService
        self.appService = appService
        self.trustedApplicationURL = trustedApplicationURL
    }

    func loadLegacyKey() throws -> Data {
        try load(service: legacyService, missing: .missingLegacyKey)
    }

    func savePendingKey(_ data: Data) throws {
        try saveAppBound(data, service: pendingService)
    }

    func loadPendingKey() throws -> Data {
        try load(service: pendingService, missing: .missingPendingKey)
    }

    func promotePendingKey() throws {
        try saveAppBound(try loadPendingKey(), service: appService)
    }

    func loadAppKey() throws -> Data {
        try load(service: appService, missing: .missingAppKey)
    }

    func deleteLegacyKey() throws { try delete(service: legacyService) }
    func deletePendingKey() throws { try delete(service: pendingService) }
    func deleteAppKey() throws { try delete(service: appService) }

    private func saveAppBound(_ data: Data, service: String) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw MigrationKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecValueData as String: data,
            kSecAttrAccess as String: try appOnlyAccess(),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try load(service: service, missing: .conflictingKey) == data else {
                throw MigrationKeyStoreError.conflictingKey
            }
            return
        }
        guard status == errSecSuccess else {
            throw MigrationKeyStoreError.securityFailure(status)
        }
    }

    private func load(
        service: String,
        missing: MigrationKeyStoreError
    ) throws -> Data {
        guard KeychainQuery.systemKeychainAllowed else {
            throw MigrationKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw missing }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MigrationKeyStoreError.securityFailure(status)
        }
        return data
    }

    private func delete(service: String) throws {
        guard KeychainQuery.systemKeychainAllowed else {
            throw MigrationKeyStoreError.securityFailure(errSecInteractionNotAllowed)
        }
        let query = KeychainQuery.forbidAuthenticationUI([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ])
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MigrationKeyStoreError.securityFailure(status)
        }
    }

    private func appOnlyAccess() throws -> SecAccess {
        // SecTrustedApplicationCreateFromPath / SecAccessCreate are deprecated,
        // but they remain the file-based login keychain boundary that binds the
        // migrated vault key to this app. Removing them would weaken commit.
        // Revisit when Apple ships a replacement that works for file keychains.
        var trustedApplication: SecTrustedApplication?
        let trustedStatus = trustedApplicationURL.path.withCString { path in
            SecTrustedApplicationCreateFromPath(path, &trustedApplication)
        }
        guard trustedStatus == errSecSuccess, let trustedApplication else {
            throw MigrationKeyStoreError.securityFailure(trustedStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Ask Key App-only vault key" as CFString,
            [trustedApplication] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw MigrationKeyStoreError.securityFailure(accessStatus)
        }
        return access
    }

}

protocol MigrationKeyStore: AnyObject {
    func loadLegacyKey() throws -> Data
    func savePendingKey(_ data: Data) throws
    func loadPendingKey() throws -> Data
    func promotePendingKey() throws
    func loadAppKey() throws -> Data
    func deleteLegacyKey() throws
    func deletePendingKey() throws
    func deleteAppKey() throws
}

enum MigrationCommitError: Error, Equatable, LocalizedError {
    case alreadyPrepared
    case noPreparedMigration
    case conflictsRequireResolution
    case rollbackNotAllowed(MigrationJournalState)
    case invalidJournal
    case legacyVaultChanged
    case promotedDatabaseInvalid
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyPrepared:
            return "A migration is already prepared."
        case .noPreparedMigration:
            return "No prepared migration was found."
        case .conflictsRequireResolution:
            return "Resolve every credential name conflict before committing the migration."
        case .rollbackNotAllowed:
            return "Migration commit has started and can only recover forward."
        case .invalidJournal:
            return "The migration journal could not be authenticated."
        case .legacyVaultChanged:
            return "The existing vault changed after migration preparation. Prepare it again before committing."
        case .promotedDatabaseInvalid:
            return "The promoted credential database does not match the prepared migration."
        case .cleanupFailed(let message):
            return "Migration cleanup failed: \(message)"
        }
    }
}

final class MigrationCommitter {
    private struct Journal: Codable {
        var state: MigrationJournalState
        let legacyDigest: Data
        let databaseDigest: Data
    }

    private let legacyDatabaseURL: URL
    private let newDatabaseURL: URL
    private let journalURL: URL
    private let keyStore: MigrationKeyStore
    private let afterStep: (MigrationJournalState) throws -> Void
    private let afterPreview: () throws -> Void
    private let afterRollbackJournalRemoved: () throws -> Void

    private var pendingDatabaseURL: URL {
        newDatabaseURL.appendingPathExtension("pending")
    }

    init(
        legacyDatabaseURL: URL,
        newDatabaseURL: URL,
        journalURL: URL,
        keyStore: MigrationKeyStore,
        afterStep: @escaping (MigrationJournalState) throws -> Void = { _ in },
        afterPreview: @escaping () throws -> Void = {},
        afterRollbackJournalRemoved: @escaping () throws -> Void = {}
    ) {
        self.legacyDatabaseURL = legacyDatabaseURL
        self.newDatabaseURL = newDatabaseURL
        self.journalURL = journalURL
        self.keyStore = keyStore
        self.afterStep = afterStep
        self.afterPreview = afterPreview
        self.afterRollbackJournalRemoved = afterRollbackJournalRemoved
    }

    func prepare(expectedSourceFingerprint: Data? = nil) throws -> MigrationPreview {
        guard try state() == nil else { throw MigrationCommitError.alreadyPrepared }
        try cleanupPreparationArtifacts()

        let legacyKeyData = try keyStore.loadLegacyKey()
        guard legacyKeyData.count == 32 else { throw VaultBootstrapError.invalidKey }
        let newKey = VaultCrypto.generateKey()
        let legacyDigest = try databaseDigest(legacyDatabaseURL)
        if let expectedSourceFingerprint, expectedSourceFingerprint != legacyDigest {
            throw MigrationCommitError.legacyVaultChanged
        }
        let preview = try MigrationPlanner(
            databaseURL: legacyDatabaseURL,
            legacyKey: VaultCrypto.keyFromData(legacyKeyData),
            migrationKey: newKey
        ).preview()
        try afterPreview()
        guard try databaseDigest(legacyDatabaseURL) == legacyDigest else {
            throw MigrationCommitError.legacyVaultChanged
        }
        guard preview.canCommit else { throw MigrationCommitError.conflictsRequireResolution }

        try createParentDirectory()
        do {
            try removeIfPresent(pendingDatabaseURL)
            let store = try VaultStore(path: pendingDatabaseURL.path)
            store.bindCredentialAuthenticationKey(newKey)
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try store.db.write { database in
                for proposal in preview.proposals {
                    let staged = proposal.stagedCredential
                    let record = CredentialRecord(
                        id: staged.id,
                        nameIndex: staged.nameIndex,
                        encryptedDisplayName: staged.encryptedDisplayName,
                        encryptedPayload: staged.encryptedPayload,
                        encryptedUsageInstructions: staged.encryptedUsageInstructions,
                        encryptedPrivateNotes: staged.encryptedPrivateNotes,
                        encryptedGroupName: staged.encryptedGroupName,
                        encryptedEnvironmentVariable: staged.encryptedEnvironmentVariable,
                        payloadKind: staged.payloadKind.rawValue,
                        permission: staged.permission.rawValue,
                        expiresAt: staged.expiresAt,
                        createdAt: staged.createdAt ?? timestamp,
                        updatedAt: staged.updatedAt ?? timestamp,
                        encryptedOriginalFilename: staged.encryptedOriginalFilename,
                        byteSize: staged.byteSize,
                        contentDigest: staged.contentDigest,
                        deletedAt: staged.deletedAt
                    )
                    try store.credentialForPersistence(record).insert(database)
                }
                let groups = try VaultCrypto.encrypt(JSONEncoder().encode(preview.groupNames), using: newKey)
                try ConfigRecord(key: "credential_groups", value: groups.base64EncodedString()).save(database)
                for record in preview.accessRecords {
                    try CredentialAccessRecord(id: record.id, encryptedRecord: record.encryptedRecord).insert(database)
                }
            }
            try store.db.writeWithoutTransaction { database in
                try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            try validateStagedDatabase(store, preview: preview, key: newKey)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: pendingDatabaseURL.path
            )
            let journal = Journal(
                state: .prepared,
                legacyDigest: legacyDigest,
                databaseDigest: try fileDigest(pendingDatabaseURL)
            )
            try keyStore.savePendingKey(VaultCrypto.keyToData(newKey))
            try writeJournal(journal, using: newKey)
            return preview
        } catch let originalError {
            do {
                try cleanupPreparationArtifacts()
            } catch {
                throw MigrationCommitError.cleanupFailed(
                    "\(error.localizedDescription); original error: \(originalError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    func state() throws -> MigrationJournalState? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        return try readJournal().state
    }

    func rollbackPrepared() throws {
        guard let currentState = try state() else {
            throw MigrationCommitError.noPreparedMigration
        }
        guard currentState == .prepared else {
            throw MigrationCommitError.rollbackNotAllowed(currentState)
        }
        guard !FileManager.default.fileExists(atPath: newDatabaseURL.path) else {
            throw MigrationCommitError.rollbackNotAllowed(.dbPromoted)
        }
        try removeIfPresent(journalURL)
        try afterRollbackJournalRemoved()
        try cleanupPreparationArtifacts()
    }

    func commit() throws {
        guard let currentState = try state() else {
            throw MigrationCommitError.noPreparedMigration
        }
        var journal = try readJournal()
        guard currentState == journal.state else { throw MigrationCommitError.invalidJournal }
        try recoverForward(&journal, beginPreparedCommit: true)
    }

    func recover() throws {
        guard let currentState = try state() else { return }
        var journal = try readJournal()
        guard currentState == journal.state else { throw MigrationCommitError.invalidJournal }
        let promotedAlready = FileManager.default.fileExists(atPath: newDatabaseURL.path)
        if journal.state == .prepared && !promotedAlready { return }
        try recoverForward(&journal, beginPreparedCommit: false)
    }

    private func recoverForward(
        _ journal: inout Journal,
        beginPreparedCommit: Bool
    ) throws {
        while journal.state != .complete {
            switch journal.state {
            case .prepared:
                guard beginPreparedCommit || FileManager.default.fileExists(atPath: newDatabaseURL.path) else {
                    return
                }
                try promoteDatabase(journal)
                try afterStep(.dbPromoted)
                journal.state = .dbPromoted
                try writeJournalWithAvailableKey(journal)
            case .dbPromoted:
                try verifyPromotedDatabase(journal)
                try keyStore.promotePendingKey()
                try afterStep(.keyPromoted)
                journal.state = .keyPromoted
                try writeJournalWithAvailableKey(journal)
            case .keyPromoted:
                try verifyPromotedDatabase(journal)
                try keyStore.deleteLegacyKey()
                try afterStep(.oldRevoked)
                journal.state = .oldRevoked
                try writeJournalWithAvailableKey(journal)
            case .oldRevoked:
                try verifyPromotedDatabase(journal)
                try keyStore.deletePendingKey()
                try afterStep(.complete)
                journal.state = .complete
                try writeJournalWithAvailableKey(journal)
            case .complete:
                return
            }
        }
    }

    private func promoteDatabase(_ journal: Journal) throws {
        if FileManager.default.fileExists(atPath: newDatabaseURL.path) {
            try verifyPromotedDatabase(journal)
            return
        }
        guard try databaseDigest(legacyDatabaseURL) == journal.legacyDigest else {
            throw MigrationCommitError.legacyVaultChanged
        }
        guard try fileDigest(pendingDatabaseURL) == journal.databaseDigest else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
        try FileManager.default.moveItem(at: pendingDatabaseURL, to: newDatabaseURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: newDatabaseURL.path
        )
    }

    private func verifyPromotedDatabase(_ journal: Journal) throws {
        guard try fileDigest(newDatabaseURL) == journal.databaseDigest else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
    }

    private func writeJournalWithAvailableKey(_ journal: Journal) throws {
        let keyData = try loadAvailableJournalKey()
        try writeJournal(journal, using: VaultCrypto.keyFromData(keyData))
    }

    private func readJournal() throws -> Journal {
        let sealedData = try Data(contentsOf: journalURL)
        let keyData = try loadAvailableJournalKey()
        do {
            let key = VaultCrypto.keyFromData(keyData)
            let cleartext = try VaultCrypto.decryptData(sealedData, using: key)
            return try JSONDecoder().decode(Journal.self, from: cleartext)
        } catch {
            throw MigrationCommitError.invalidJournal
        }
    }

    private func loadAvailableJournalKey() throws -> Data {
        let keyData: Data
        do {
            keyData = try keyStore.loadAppKey()
        } catch MigrationKeyStoreError.missingAppKey {
            keyData = try keyStore.loadPendingKey()
        } catch {
            throw error
        }
        return keyData
    }

    private func writeJournal(_ journal: Journal, using key: SymmetricKey) throws {
        let cleartext = try JSONEncoder().encode(journal)
        let sealed = try VaultCrypto.encrypt(cleartext, using: key)
        try sealed.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: journalURL.path
        )
    }

    private func createParentDirectory() throws {
        let directory = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func databaseDigest(_ url: URL) throws -> Data {
        try MigrationSourceFingerprint.digest(of: url)
    }

    private func fileDigest(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
        return Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    private func validateStagedDatabase(
        _ store: VaultStore,
        preview: MigrationPreview,
        key: SymmetricKey
    ) throws {
        let records = try store.fetchAllCredentials() + store.fetchRecycledCredentials()
        let expected = Dictionary(uniqueKeysWithValues: preview.proposals.map {
            ($0.stagedCredential.id, $0.stagedCredential)
        })
        guard records.count == expected.count else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
        for record in records {
            guard let staged = expected[record.id],
                  record.nameIndex == staged.nameIndex,
                  record.encryptedDisplayName == staged.encryptedDisplayName,
                  record.encryptedPayload == staged.encryptedPayload,
                  record.encryptedUsageInstructions == staged.encryptedUsageInstructions,
                  record.encryptedPrivateNotes == staged.encryptedPrivateNotes,
                  record.encryptedGroupName == staged.encryptedGroupName,
                  record.payloadKind == staged.payloadKind.rawValue,
                  record.permission == staged.permission.rawValue,
                  record.encryptedEnvironmentVariable == staged.encryptedEnvironmentVariable,
                  record.encryptedOriginalFilename == staged.encryptedOriginalFilename,
                  record.byteSize == staged.byteSize,
                  record.contentDigest == staged.contentDigest,
                  record.expiresAt == staged.expiresAt,
                  record.deletedAt == staged.deletedAt,
                  staged.createdAt == nil || record.createdAt == staged.createdAt,
                  staged.updatedAt == nil || record.updatedAt == staged.updatedAt else {
                throw MigrationCommitError.promotedDatabaseInvalid
            }
        }
        guard let encodedGroups = try store.configValue(key: "credential_groups"),
              let groupCiphertext = Data(base64Encoded: encodedGroups),
              try JSONDecoder().decode([String].self, from: VaultCrypto.decryptData(groupCiphertext, using: key)) == preview.groupNames else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
        let access = try store.fetchCredentialAccessRecords()
        guard Set(access.map(\.id)) == Set(preview.accessRecords.map(\.id)),
              access.allSatisfy({ record in
                  preview.accessRecords.contains { $0.id == record.id && $0.encryptedRecord == record.encryptedRecord }
              }) else { throw MigrationCommitError.promotedDatabaseInvalid }
    }

    private func cleanupPreparationArtifacts() throws {
        try removeIfPresent(pendingDatabaseURL)
        try removeIfPresent(URL(fileURLWithPath: pendingDatabaseURL.path + "-wal"))
        try removeIfPresent(URL(fileURLWithPath: pendingDatabaseURL.path + "-shm"))
        try keyStore.deletePendingKey()
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
