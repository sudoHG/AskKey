import Foundation
import GRDB
import AskKeyBroker

extension VaultStore {
    func insertCredential(_ record: CredentialRecord) throws {
        try db.write { db in
            try credentialForPersistence(record).insert(db)
        }
    }

    func updateCredential(_ record: CredentialRecord) throws {
        try db.write { db in
            guard let current = try CredentialRecord.fetchOne(db, key: record.id) else {
                throw VaultError.credentialNotFound(record.id)
            }
            _ = try authenticatedCredential(current)
            try credentialForPersistence(record).update(db)
        }
    }

    func updateFileCredentialPayload(
        id: String,
        encryptedPayload: Data,
        encryptedOriginalFilename: Data,
        byteSize: Int,
        contentDigest: Data,
        expectedContentDigest: Data
    ) throws {
        try db.write { db in
            guard let fetched = try CredentialRecord.fetchOne(db, key: id) else {
                throw VaultError.credentialChanged
            }
            var record = try authenticatedCredential(fetched)
            guard record.payloadKind == CredentialPayloadKind.file.rawValue,
                  record.contentDigest == expectedContentDigest,
                  record.deletedAt == nil else { throw VaultError.credentialChanged }
            record.encryptedPayload = encryptedPayload
            record.encryptedOriginalFilename = encryptedOriginalFilename
            record.byteSize = byteSize
            record.contentDigest = contentDigest
            record.updatedAt = iso8601()
            try credentialForPersistence(record).update(db)
        }
    }

    func deleteCredential(id: String) throws {
        try db.write { db in
            if let record = try CredentialRecord.fetchOne(db, key: id) {
                _ = try authenticatedCredential(record)
            }
            let deleted = try CredentialRecord.filter(Column("id") == id).deleteAll(db)
            guard deleted > 0 else { throw VaultError.credentialNotFound(id) }
        }
    }

    func recycleCredential(id: String, deletedAt: String) throws {
        try db.write { db in
            guard let fetched = try CredentialRecord.fetchOne(db, key: id) else {
                throw VaultError.credentialNotFound(id)
            }
            var record = try authenticatedCredential(fetched)
            guard record.deletedAt == nil else { throw VaultError.credentialNotFound(id) }
            record.deletedAt = deletedAt
            try credentialForPersistence(record).update(db)
        }
    }

    func restoreCredential(id: String) throws {
        try db.write { db in
            guard let fetched = try CredentialRecord.fetchOne(db, key: id) else {
                throw VaultError.credentialNotFound(id)
            }
            var record = try authenticatedCredential(fetched)
            guard record.deletedAt != nil else { throw VaultError.credentialNotFound(id) }
            record.deletedAt = nil
            try credentialForPersistence(record).update(db)
        }
    }

    func deleteRecycledCredential(id: String) throws {
        try db.write { db in
            if let record = try CredentialRecord.fetchOne(db, key: id) {
                _ = try authenticatedCredential(record)
            }
            let deleted = try CredentialRecord
                .filter(Column("id") == id && Column("deleted_at") != nil)
                .deleteAll(db)
            guard deleted > 0 else { throw VaultError.credentialNotFound(id) }
        }
    }

    func purgeRecycledCredentials(deletedOnOrBefore cutoff: String) throws -> Int {
        try db.write { db in
            let records = try CredentialRecord
                .filter(Column("deleted_at") != nil && Column("deleted_at") <= cutoff)
                .fetchAll(db)
            for record in records { _ = try authenticatedCredential(record) }
            return try CredentialRecord.filter(records.map(\.id).contains(Column("id"))).deleteAll(db)
        }
    }

    func fetchCredential(id: String) throws -> CredentialRecord? {
        try db.read { db in
            try CredentialRecord
                .filter(Column("id") == id && Column("deleted_at") == nil)
                .fetchOne(db)
                .map(authenticatedCredential)
        }
    }

    func fetchCredential(nameIndex: Data) throws -> CredentialRecord? {
        try db.read { db in
            try CredentialRecord
                .filter(Column("name_index") == nameIndex && Column("deleted_at") == nil)
                .fetchOne(db)
                .map(authenticatedCredential)
        }
    }

    func fetchCredentialIncludingRecycled(nameIndex: Data) throws -> CredentialRecord? {
        try db.read { db in
            try CredentialRecord.filter(Column("name_index") == nameIndex).fetchOne(db)
                .map(authenticatedCredential)
        }
    }

    func fetchAllCredentials() throws -> [CredentialRecord] {
        try db.read { db in
            try CredentialRecord.filter(Column("deleted_at") == nil).fetchAll(db)
                .map(authenticatedCredential)
        }
    }

    /// Full-library backups include the recycle bin in the same authenticated read.
    func fetchAllCredentialsIncludingRecycled() throws -> [CredentialRecord] {
        try db.read { db in
            try CredentialRecord.fetchAll(db).map(authenticatedCredential)
        }
    }

    func fetchRecycledCredentials() throws -> [CredentialRecord] {
        try db.read { db in
            try CredentialRecord
                .filter(Column("deleted_at") != nil)
                .order(Column("deleted_at"))
                .fetchAll(db)
                .map(authenticatedCredential)
        }
    }

    func fetchAllCredentials(cancellation: BrokerCancellation) throws -> [CredentialRecord] {
        let admission = try brokerCatalogReadGate.acquire(cancellation: cancellation)
        // GRDB documents DatabaseWriter.interrupt as the cancellation entry for
        // an in-flight read. Broker catalog cancellation depends on that hop;
        // the queue is shared across those reads and this is not a data race.
        let queue = db
        let interrupt: @Sendable () -> Void = { queue.interrupt() }
        let operation = CancellableCredentialRead(
            admission: admission, interrupt: interrupt,
            authenticate: { try self.authenticatedCredential($0) }
        )
        cancellation.onCancel { [weak operation] in operation?.cancel() }
        db.asyncRead { result in operation.execute(result) }
        return try operation.wait()
    }

}

final class BrokerCatalogReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let limit: Int
    private var reserved = 0

    init(limit: Int) {
        self.limit = limit
    }

    var reservedCount: Int {
        condition.lock(); defer { condition.unlock() }
        return reserved
    }

    func acquire(cancellation: BrokerCancellation) throws -> BrokerCatalogReadAdmission {
        cancellation.onCancel { [weak self] in self?.wakeWaiters() }
        condition.lock()
        while reserved >= limit {
            do {
                try cancellation.check()
            } catch {
                condition.unlock()
                throw error
            }
            condition.wait()
        }
        reserved += 1
        condition.unlock()

        let admission = BrokerCatalogReadAdmission(gate: self)
        do {
            try cancellation.check()
            return admission
        } catch {
            admission.release()
            throw error
        }
    }

    fileprivate func release() {
        condition.lock()
        if reserved > 0 { reserved -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    private func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

final class BrokerCatalogReadAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private weak var gate: BrokerCatalogReadGate?
    private var released = false

    init(gate: BrokerCatalogReadGate) {
        self.gate = gate
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        let currentGate = gate
        lock.unlock()
        currentGate?.release()
    }

    deinit { release() }
}

final class CancellableCredentialRead: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private let admission: BrokerCatalogReadAdmission
    private let interrupt: @Sendable () -> Void
    private let authenticate: (CredentialRecord) throws -> CredentialRecord
    private var running = false
    private var completed = false
    private var result: Result<[CredentialRecord], Error>?

    init(
        admission: BrokerCatalogReadAdmission,
        interrupt: @escaping @Sendable () -> Void,
        authenticate: @escaping (CredentialRecord) throws -> CredentialRecord
    ) {
        self.admission = admission
        self.interrupt = interrupt
        self.authenticate = authenticate
    }

    func cancel() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        // Keep the queue's interrupt owned by this callback until it is sent.
        // execute() must take this same lock before returning to GRDB, so a
        // successor cannot begin between observing running and interrupting.
        if running { interrupt() }
        lock.unlock()
        completion.signal()
    }

    func execute(_ database: Result<Database, Error>) {
        defer { admission.release() }
        lock.lock()
        guard !completed else { lock.unlock(); return }
        running = true
        lock.unlock()

        let fetched = Result {
            try CredentialRecord
                .filter(Column("deleted_at") == nil)
                .fetchAll(database.get())
                .map(authenticate)
        }

        lock.lock()
        running = false
        guard !completed else { lock.unlock(); return }
        result = fetched
        completed = true
        lock.unlock()
        completion.signal()
    }

    func wait() throws -> [CredentialRecord] {
        completion.wait()
        lock.lock(); defer { lock.unlock() }
        guard let result else { throw BrokerCancellationError.cancelled }
        return try result.get()
    }
}
