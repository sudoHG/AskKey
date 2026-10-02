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

    /// `validation` runs on the private preflight copy and again on the opened
    /// connection before any migration-table write.
    init(path: String, authenticationKey: SymmetricKey? = nil,
         validation: (Database) throws -> Void = { _ in }) throws {
        self.path = path
        let exists = try CurrentLibrarySnapshot.regularFileExists(URL(fileURLWithPath: path))
        guard exists || authenticationKey == nil else { throw VaultBootstrapError.missingDatabase }
        var opening: CurrentLibrarySchema.Opening?
        var proof: CurrentLibrarySnapshot.Proof?
        defer { proof = nil }
        if exists {
            // Validate a private copy before SQLite can touch original sidecars.
            try CurrentLibrarySnapshot.withVerifiedCopy(of: URL(fileURLWithPath: path)) { snapshot, verified in
                let probe = try DatabaseQueue(path: snapshot.path)
                defer { try? probe.close() }
                opening = try probe.read {
                    let opening = try CurrentLibrarySchema.opening($0)
                    if let authenticationKey { try Self.validateCredentialRows($0, key: authenticationKey) }
                    try validation($0)
                    return opening
                }
                proof = verified
            }
        }
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            if let proof {
                // GRDB calls this before validating the format or opening WAL
                // bookkeeping. Reject any change since private-copy validation.
                //
                // Defense in depth only, not a guarantee. AskKey assumes it is
                // the only process that opens the library (#31 concurrency
                // scope; see SECURITY.md). No file lock is held after this
                // check, so a same-user process can still change the files
                // between it and SQLite's first schema or WAL read, or later.
                // Normal SQLite transaction revalidation of the schema and
                // credential authentication still applies.
                try proof.validate(URL(fileURLWithPath: path))
                var moved: CInt = 0
                guard sqlite3_file_control(database.sqliteConnection, nil, SQLITE_FCNTL_HAS_MOVED, &moved) == SQLITE_OK,
                      moved == 0 else { throw VaultBootstrapError.invalidState }
            }
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
        let openingPath: String
        if exists {
            // GRDB's writable flags include CREATE. A recognized SQLite URI
            // narrows them to read-write without creating a disappeared file.
            guard sqlite3_compileoption_used("USE_URI") != 0,
                  var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false) else {
                throw VaultBootstrapError.invalidState
            }
            components.queryItems = [URLQueryItem(name: "mode", value: "rw")]
            guard let uri = components.url else { throw VaultBootstrapError.invalidState }
            openingPath = uri.absoluteString
        } else {
            openingPath = path
        }
        db = try DatabaseQueue(path: openingPath, configuration: configuration)
        if opening == .legacyV15 {
            try db.write { database in
                try CurrentLibrarySchema.adoptLegacyV15(database) {
                    if let authenticationKey { try Self.validateCredentialRows($0, key: authenticationKey) }
                    try validation($0)
                }
            }
        } else if exists {
            try db.read { database in
                guard try CurrentLibrarySchema.opening(database) == .baseline else {
                    throw VaultBootstrapError.invalidState
                }
                if let authenticationKey { try Self.validateCredentialRows(database, key: authenticationKey) }
                try validation(database)
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
