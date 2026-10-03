import Foundation
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

    func replaceCredentialGroupsConfig(
        key: String,
        value: String,
        clearingCredentialIDs: [String],
        updatedAt: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
            for id in clearingCredentialIDs {
                guard let fetched = try CredentialRecord.fetchOne(db, key: id) else { continue }
                var record = try authenticatedCredential(fetched)
                record.encryptedGroupName = nil
                record.updatedAt = updatedAt
                try credentialForPersistence(record).update(db)
            }
        }
    }
}
