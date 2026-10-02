import Foundation
import CryptoKit
import GRDB
import AskKeyBroker

final class VaultStore {
    let db: DatabaseQueue
    let brokerCatalogReadGate = BrokerCatalogReadGate(limit: BrokerLimits.maximumConcurrentRequests)
    private let path: String
    private let authenticationLock = NSLock()
    private var credentialAuthenticationKey: SymmetricKey?

    func bindCredentialAuthenticationKey(_ key: SymmetricKey?) {
        authenticationLock.lock()
        credentialAuthenticationKey = key
        authenticationLock.unlock()
    }

    private func requireCredentialAuthenticationKey() throws -> SymmetricKey {
        authenticationLock.lock()
        defer { authenticationLock.unlock() }
        guard let key = credentialAuthenticationKey else { throw VaultError.vaultLocked }
        return key
    }

    func credentialForPersistence(_ record: CredentialRecord) throws -> CredentialRecord {
        try CredentialRecordAuthentication.seal(record, using: requireCredentialAuthenticationKey())
    }

    func authenticatedCredential(_ record: CredentialRecord) throws -> CredentialRecord {
        try CredentialRecordAuthentication.verify(record, using: requireCredentialAuthenticationKey())
        return record
    }

    init(path: String, authenticationKey: SymmetricKey? = nil) throws {
        self.path = path
        let exists = try CurrentLibrarySnapshot.regularFileExists(URL(fileURLWithPath: path))
        var opening: CurrentLibrarySchema.Opening?
        if exists {
            // Validate a private copy before SQLite can touch original sidecars.
            try CurrentLibrarySnapshot.withCopy(of: URL(fileURLWithPath: path)) { snapshot in
                let probe = try DatabaseQueue(path: snapshot.path)
                defer { try? probe.close() }
                opening = try probe.read {
                    let opening = try CurrentLibrarySchema.opening($0)
                    if let authenticationKey { try Self.validateCredentialRows($0, key: authenticationKey) }
                    return opening
                }
            }
        }
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            // Let SQLite checkpoint and remove its own current WAL sidecars
            // when the last connection closes. Persisted WAL indexes would be
            // rebuilt by a second open even when no database row changed.
            var persistWAL: CInt = 0
            let result = sqlite3_file_control(database.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
            guard result == SQLITE_OK else {
                throw DatabaseError(resultCode: ResultCode(rawValue: result))
            }
        }
        if !exists { configuration.journalMode = .wal }
        db = try DatabaseQueue(path: path, configuration: configuration)
        if opening == .legacyV15 {
            try db.write { database in
                try CurrentLibrarySchema.adoptLegacyV15(database) {
                    if let authenticationKey { try Self.validateCredentialRows($0, key: authenticationKey) }
                }
            }
        } else if exists {
            try db.read { database in
                guard try CurrentLibrarySchema.opening(database) == .baseline else {
                    throw VaultBootstrapError.invalidState
                }
                if let authenticationKey { try Self.validateCredentialRows(database, key: authenticationKey) }
            }
        } else {
            try migrate()
        }
    }

    init(readOnlyPath path: String) throws {
        self.path = path
        var config = Configuration()
        config.readonly = true
        db = try DatabaseQueue(path: path, configuration: config)
    }

    private static func validateCredentialRows(_ db: Database, key: SymmetricKey) throws {
        for record in try CredentialRecord.fetchAll(db) {
            _ = try CredentialRecordAuthentication.verify(record, using: key)
        }
    }

    /// Returns a connection that preserves reads for diagnostics while SQLite
    /// rejects every write to the quiesced store.
    func quiescedCopy() throws -> VaultStore {
        try VaultStore(readOnlyPath: path)
    }

    /// Waits for the serialized database queue to drain, then invalidates this
    /// connection so callers that retained the old store can no longer write.
    func close() throws {
        try db.close()
    }

    var pendingBrokerCatalogReadCount: Int { brokerCatalogReadGate.reservedCount }
}
