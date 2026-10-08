import Foundation
import CryptoKit
import GRDB

extension VaultStore {
    // MARK: - Config

    func configValue(key: String) throws -> String? {
        try db.read { db in
            try ConfigRecord.filter(Column("key") == key).fetchOne(db)?.value
        }
    }

    func setConfigValue(key: String, value: String?) throws {
        try db.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM config WHERE key = ?", arguments: [key])
            }
        }
    }

    func editCredentialGroup(
        _ name: String,
        key: SymmetricKey,
        deleting: Bool,
        updatedAt: String
    ) throws -> [String] {
        try db.write { db in
            let configKey = Vault.credentialGroupsConfigKey
            let current = try ConfigRecord.fetchOne(db, key: configKey)?.value
            var groups = Set(try AgentOrganizationSnapshot.storedGroups(current, key: key))
            if deleting { groups.remove(name) } else { groups.insert(name) }
            let value = try VaultCrypto.encrypt(JSONEncoder().encode(groups.sorted()), using: key).base64EncodedString()
            try db.execute(
                sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                arguments: [configKey, value]
            )
            var clearedIDs: [String] = []
            if deleting {
                for fetched in try CredentialRecord.fetchAll(db) {
                    var record = try authenticatedCredential(fetched)
                    guard let encrypted = record.encryptedGroupName,
                          try VaultCrypto.decrypt(encrypted, using: key) == name else { continue }
                    record.encryptedGroupName = nil
                    record.updatedAt = updatedAt
                    try credentialForPersistence(record).update(db)
                    clearedIDs.append(record.id)
                }
            }
            return clearedIDs
        }
    }
}
