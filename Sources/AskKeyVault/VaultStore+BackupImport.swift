import CryptoKit
import Foundation
import GRDB

extension VaultStore {
    /// Writes a whole import plan in one transaction. The library state is
    /// read and compared with the plan's digest inside the transaction, and
    /// the stored groups are merged into their transaction-current value like
    /// every other stored-group writer (ADR 0010). Only new rows are inserted
    /// and the stored group list only gains names; any failure rolls back
    /// every planned credential and group.
    func commitBackupImport(_ records: [CredentialRecord], storedGroups addedGroups: [String],
                            libraryDigest: Data, key: SymmetricKey) throws {
        try db.write { db in
            let configKey = Vault.credentialGroupsConfigKey
            let storedGroups = try AgentOrganizationSnapshot.storedGroups(
                ConfigRecord.fetchOne(db, key: configKey)?.value, key: key)
            let current = AgentOrganizationSnapshot(
                records: try CredentialRecord.fetchAll(db).map(authenticatedCredential), storedGroups: storedGroups)
            guard try BackupImportLibraryState.digest(current, key: key) == libraryDigest else {
                throw BackupImportError.libraryChanged
            }
            for record in records { try credentialForPersistence(record).insert(db) }
            let groups = Set(storedGroups).union(addedGroups)
            if groups != Set(storedGroups) {
                let value = try VaultCrypto.encrypt(JSONEncoder().encode(groups.sorted()), using: key).base64EncodedString()
                try db.execute(sql: "INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)",
                               arguments: [configKey, value])
            }
        }
    }
}
