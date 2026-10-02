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

    init(path: String) throws {
        self.path = path
        var config = Configuration()
        config.journalMode = .wal
        db = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    private init(readOnlyPath path: String) throws {
        self.path = path
        var config = Configuration()
        config.readonly = true
        db = try DatabaseQueue(path: path, configuration: config)
    }

    /// Returns a connection that preserves reads for diagnostics while SQLite
    /// rejects every write after migration commit begins.
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
