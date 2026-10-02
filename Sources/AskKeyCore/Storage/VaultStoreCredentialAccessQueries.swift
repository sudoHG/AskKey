import Foundation
import GRDB

extension VaultStore {
    func insertCredentialAccessRecord(_ record: CredentialAccessRecord, capacity: Int) throws {
        try db.write { db in
            try record.insert(db)
            try db.execute(sql: """
                DELETE FROM credential_access_records
                WHERE rowid NOT IN (
                    SELECT rowid FROM credential_access_records ORDER BY rowid DESC LIMIT ?
                )
                """, arguments: [capacity])
        }
    }

    func fetchCredentialAccessRecords() throws -> [CredentialAccessRecord] {
        try db.read { db in
            try CredentialAccessRecord.order(Column.rowID.desc).fetchAll(db)
        }
    }

    func deleteCredentialAccessRecords(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        _ = try db.write { db in
            try CredentialAccessRecord.filter(ids.contains(Column("id"))).deleteAll(db)
        }
    }

    func deleteAllCredentialAccessRecords() throws {
        try db.write { db in _ = try CredentialAccessRecord.deleteAll(db) }
    }

    func rawCredentialAccessRecords() throws -> [CredentialAccessRecord] {
        try fetchCredentialAccessRecords()
    }

    func failCredentialAccessRecordWritesForTesting() throws {
        try db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_credential_access_record_write
                BEFORE INSERT ON credential_access_records
                BEGIN SELECT RAISE(FAIL, 'injected access record failure'); END
                """)
        }
    }
}
