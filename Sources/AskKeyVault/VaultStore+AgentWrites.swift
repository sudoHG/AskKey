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
        expectedFileDigest: Data? = nil
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
