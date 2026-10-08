import CryptoKit
import Foundation
import GRDB
import AskKeyBroker

extension VaultStore {
    func agentOrganizationSnapshot(key: SymmetricKey) throws -> AgentOrganizationSnapshot {
        try db.read { db in try agentOrganizationSnapshot(key: key, db: db) }
    }

    private func agentOrganizationSnapshot(key: SymmetricKey, db: Database) throws -> AgentOrganizationSnapshot {
        let config = try ConfigRecord.fetchOne(db, key: Vault.credentialGroupsConfigKey)?.value
        let records = try CredentialRecord.fetchAll(db).map(authenticatedCredential)
        guard records.allSatisfy({ CredentialPermission(rawValue: $0.permission) != nil }) else {
            throw VaultError.databaseError("Credential has an unknown permission.")
        }
        return .init(records: records,
            storedGroups: try AgentOrganizationSnapshot.storedGroups(config, key: key))
    }

    func commitAgentOrganization(_ frozen: FrozenAgentOrganization, requestID: String,
                                 capabilityDigest: String, key: SymmetricKey,
                                 clock: () -> Date) throws -> AgentTextWriteResult {
        try db.write { db in
            let snapshot = try agentOrganizationSnapshot(key: key, db: db)
            let names = Set(frozen.groups.map(\.normalizedName))
            guard try snapshot.groupStates(names: names, key: key) == frozen.groups else {
                throw VaultError.credentialChanged
            }
            let records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let committedAt = clock()
            for before in frozen.before {
                guard let current = records[before.id],
                      try encoder.encode(current) == encoder.encode(before) else {
                    throw VaultError.credentialChanged
                }
                if frozen.movedCredentialIDs.contains(before.id) {
                    guard current.deletedAt == nil, current.permission != CredentialPermission.hidden.rawValue else {
                        throw VaultError.credentialUnavailable
                    }
                    if let expiry = current.expiresAt {
                        guard let date = sharedDateFormatter.date(from: expiry), date > committedAt else {
                            throw VaultError.credentialUnavailable
                        }
                    }
                }
            }
            // Merge only named groups into transaction-current state; unrelated
            // App group edits survive this batch.
            var groups = Set(snapshot.storedGroups).union(try snapshot.assignments(key: key).values)
            groups = Set(groups.filter { !names.contains(CredentialName.normalized($0)) })
            groups.formUnion(frozen.finalGroupNames)
            let value = try VaultCrypto.encrypt(JSONEncoder().encode(groups.sorted()), using: key).base64EncodedString()
            for record in frozen.after { try credentialForPersistence(record).update(db) }
            try db.execute(sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                arguments: [Vault.credentialGroupsConfigKey, value])
            try AgentWriteOperationRecord(operationId: frozen.request.operationID, payloadDigest: frozen.digest,
                credentialId: "", operation: BrokerApprovalOperation.organize.rawValue,
                committedAt: sharedDateFormatter.string(from: committedAt), requestId: requestID,
                capabilityDigest: capabilityDigest).insert(db)
            return .init(operationID: frozen.request.operationID, credentialID: "")
        }
    }
}
