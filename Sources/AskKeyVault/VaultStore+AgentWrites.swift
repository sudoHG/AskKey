import CryptoKit
import Foundation
import GRDB
import AskKeyBroker

extension VaultStore {
    func fetchAgentWriteOperation(operationID: String) throws -> AgentWriteOperationRecord? {
        try db.read { db in
            try AgentWriteOperationRecord.fetchOne(db, key: operationID)
        }
    }

    func fetchAgentFileWriteReceipt(requestID: String) throws -> AgentWriteOperationRecord? {
        try db.read { db in
            let records = try AgentWriteOperationRecord.filter(Column("request_id") == requestID).fetchAll(db)
            guard records.count <= 1 else { throw BrokerApprovalError.payloadMismatch }
            return records.first
        }
    }

    func commitAgentTextWrite(
        _ frozen: FrozenAgentTextWrite,
        requestID: String,
        capabilityDigest: String,
        clock: () -> Date,
        resultDigest: String? = nil,
        expectedFileDigest: Data? = nil,
        credentialGroupsKey: SymmetricKey? = nil
    ) throws -> AgentTextWriteResult {
        try db.write { db in
            let committedAt = clock()
            if let existing = try AgentWriteOperationRecord.fetchOne(db, key: frozen.operationID) {
                guard existing.payloadDigest == frozen.digest,
                      existing.resultDigest == resultDigest else {
                    throw BrokerApprovalError.payloadMismatch
                }
                guard existing.requestId == requestID,
                      existing.capabilityDigest == capabilityDigest else {
                    throw BrokerApprovalError.requestNotFound
                }
                return .init(operationID: existing.operationId, credentialID: existing.credentialId)
            }

            if let group = frozen.groupAssignment {
                guard let key = credentialGroupsKey else { throw VaultError.vaultLocked }
                try commitAgentGroup(group, creationApproved: frozen.summary?.createsGroup == true, key: key, db: db)
            }
            let credentialID: String
            let operation: BrokerApprovalOperation
            switch frozen.mutation {
            case let .create(record):
                try credentialForPersistence(record).insert(db)
                credentialID = record.id
                operation = .create
            case let .modify(record, expectedUpdatedAt):
                guard let current = try CredentialRecord.fetchOne(db, key: record.id),
                      current.deletedAt == nil,
                      current.updatedAt == expectedUpdatedAt else {
                    throw VaultError.credentialChanged
                }
                _ = try authenticatedCredential(current)
                if let expectedFileDigest, current.contentDigest != expectedFileDigest {
                    throw VaultError.credentialChanged
                }
                try requireAgentWriteCredentialUnexpired(current, at: committedAt)
                try credentialForPersistence(record).update(db)
                credentialID = record.id
                operation = .modify
            case let .delete(id, expectedUpdatedAt, deletedAt):
                guard let current = try CredentialRecord.fetchOne(db, key: id),
                      current.deletedAt == nil,
                      current.updatedAt == expectedUpdatedAt else {
                    throw VaultError.credentialChanged
                }
                _ = try authenticatedCredential(current)
                try requireAgentWriteCredentialUnexpired(current, at: committedAt)
                var recycled = current
                recycled.deletedAt = deletedAt
                try credentialForPersistence(recycled).update(db)
                credentialID = id
                operation = .delete
            }
            try AgentWriteOperationRecord(
                operationId: frozen.operationID,
                payloadDigest: frozen.digest,
                credentialId: credentialID,
                operation: operation.rawValue,
                committedAt: sharedDateFormatter.string(from: committedAt),
                requestId: requestID,
                capabilityDigest: capabilityDigest,
                resultDigest: resultDigest
            ).insert(db)
            return .init(operationID: frozen.operationID, credentialID: credentialID)
        }
    }

    /// Merge against transaction-current groups so concurrent writes cannot
    /// overwrite another group's creation or change the approved spelling.
    private func commitAgentGroup(_ name: String, creationApproved: Bool, key: SymmetricKey, db: Database) throws {
        let configKey = Vault.credentialGroupsConfigKey
        var stored: [String] = []
        if let value = try ConfigRecord.filter(Column("key") == configKey).fetchOne(db)?.value {
            guard let bytes = Data(base64Encoded: value) else { throw VaultError.databaseError("Credential groups are invalid.") }
            stored = try JSONDecoder().decode([String].self, from: VaultCrypto.decryptData(bytes, using: key))
        }
        var groups = Set(stored)
        // Include groups represented only by active or recycled credentials.
        for raw in try CredentialRecord.fetchAll(db) {
            let record = try authenticatedCredential(raw)
            if let encrypted = record.encryptedGroupName {
                groups.insert(try VaultCrypto.decrypt(encrypted, using: key))
            }
        }
        let matching = groups.filter { CredentialName.normalized($0) == CredentialName.normalized(name) }
        guard matching.allSatisfy({ $0 == name }) else { throw VaultError.credentialChanged }
        guard creationApproved || matching.contains(name) else { throw VaultError.credentialChanged }
        if !stored.contains(name) {
            stored.append(name)
            let encrypted = try VaultCrypto.encrypt(JSONEncoder().encode(stored.sorted()), using: key).base64EncodedString()
            try db.execute(sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)", arguments: [configKey, encrypted])
        }
    }

    private func requireAgentWriteCredentialUnexpired(
        _ record: CredentialRecord,
        at now: Date
    ) throws {
        guard let storedExpiry = record.expiresAt else { return }
        guard let expiry = sharedDateFormatter.date(from: storedExpiry) else {
            throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
        }
        guard expiry > now else { throw VaultError.credentialUnavailable }
    }
}
