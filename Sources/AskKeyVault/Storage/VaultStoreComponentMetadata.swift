import CryptoKit
import GRDB

extension VaultStore {
    /// The caller holds the exclusive reopening gate. SQLite rolls back every
    /// metadata/tag pair on failure or interruption; timestamps and payloads stay intact.
    func backfillComponentMetadata(
        using key: SymmetricKey,
        components: (CredentialRecord) throws -> [CredentialComponentInput]
    ) throws {
        try db.write { db in
            for var record in try CredentialRecord.order(Column("id")).fetchAll(db) {
                try CredentialRecordAuthentication.verify(record, using: key)
                guard record.encryptedComponentMetadata == nil else { continue }
                record.encryptedComponentMetadata = try CredentialComponentMetadata(
                    components: components(record)
                ).encrypted(using: key)
                try CredentialRecordAuthentication.seal(record, using: key).update(db)
            }
        }
    }
}
