import Foundation
import GRDB

enum CurrentLibrarySchema {
    static let baselineIdentifier = "askkey-0001-baseline"
    static let dropLegacyTablesIdentifier = "askkey-0002-drop-legacy-tables"
    static let currentIdentifiers = [baselineIdentifier, dropLegacyTablesIdentifier]
    static let legacyIdentifiers = [
        "v1", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11",
        "v12-remove-folder-associations", "v13-remove-project-path",
        "v14-authenticated-credentials", "v15-file-write-receipts",
    ]

    // The v15 CREATE statements are preserved verbatim, including old tables.
    static let baselineSQL = """
    CREATE TABLE "config" ("key" TEXT PRIMARY KEY, "value" TEXT NOT NULL);
    CREATE TABLE "projects" ("id" TEXT PRIMARY KEY, "name" TEXT NOT NULL UNIQUE, "active_environment" TEXT, "icon" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL);
    CREATE TABLE "environments" ("id" TEXT PRIMARY KEY, "project_id" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "color" TEXT, "created_at" TEXT NOT NULL, UNIQUE ("project_id", "name"));
    CREATE TABLE "secrets" ("id" TEXT PRIMARY KEY, "project_id" TEXT NOT NULL REFERENCES "projects"("id") ON DELETE CASCADE, "name" TEXT NOT NULL, "description" TEXT, "icon" TEXT, "category" TEXT NOT NULL DEFAULT 'secret', "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "agent_access" TEXT NOT NULL DEFAULT 'allowed', UNIQUE ("project_id", "name"));
    CREATE TABLE "secret_values" ("id" TEXT PRIMARY KEY, "secret_id" TEXT NOT NULL REFERENCES "secrets"("id") ON DELETE CASCADE, "environment_id" TEXT REFERENCES "environments"("id") ON DELETE CASCADE, "encrypted_value" BLOB NOT NULL, "updated_at" TEXT NOT NULL, UNIQUE ("secret_id", "environment_id"));
    CREATE UNIQUE INDEX secret_values_unique_default_environment
        ON secret_values(secret_id)
        WHERE environment_id IS NULL;
    CREATE TABLE "activity_log" ("id" TEXT PRIMARY KEY, "secret_name" TEXT NOT NULL, "project_name" TEXT NOT NULL, "environment_name" TEXT NOT NULL, "source" TEXT NOT NULL, "accessed_at" TEXT NOT NULL, "agent" TEXT, "action" TEXT NOT NULL DEFAULT 'read', "peer_team" TEXT);
    CREATE TABLE "credentials" ("id" TEXT PRIMARY KEY, "name_index" BLOB NOT NULL UNIQUE, "encrypted_display_name" BLOB NOT NULL, "encrypted_payload" BLOB NOT NULL, "encrypted_usage_instructions" BLOB NOT NULL, "encrypted_private_notes" BLOB NOT NULL, "encrypted_group_name" BLOB, "encrypted_environment_variable" BLOB, "payload_kind" TEXT NOT NULL, "permission" TEXT NOT NULL, "expires_at" TEXT, "created_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL, "encrypted_original_filename" BLOB, "byte_size" INTEGER, "content_digest" BLOB, "deleted_at" TEXT, "authentication_tag" BLOB);
    CREATE TABLE "agent_write_operations" ("operation_id" TEXT PRIMARY KEY, "payload_digest" TEXT NOT NULL, "credential_id" TEXT NOT NULL, "operation" TEXT NOT NULL, "committed_at" TEXT NOT NULL, "request_id" TEXT NOT NULL, "capability_digest" TEXT NOT NULL, "result_digest" TEXT);
    CREATE TABLE "credential_access_records" ("id" TEXT PRIMARY KEY, "encrypted_record" BLOB NOT NULL);
    CREATE INDEX "agent_write_operations_request_id" ON "agent_write_operations"("request_id");
    """

    /// Lokalite tables that no current code reads, children before parents.
    /// Dropping a table also drops its indexes, including
    /// `secret_values_unique_default_environment` and the SQLite autoindexes.
    static let legacyTables = ["secret_values", "secrets", "environments", "projects", "activity_log"]

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(baselineIdentifier) { db in
            try db.execute(sql: baselineSQL)
            // The legacy Default seed; askkey-0002 drops it with the legacy tables.
            let projectID = UUID().uuidString
            let environmentID = UUID().uuidString
            let now = iso8601()
            try db.execute(sql: """
                INSERT INTO projects (id, name, active_environment, icon, created_at, updated_at)
                VALUES (?, 'Default', 'Default', 'folder', ?, ?)
                """, arguments: [projectID, now, now])
            try db.execute(sql: """
                INSERT INTO environments (id, project_id, name, created_at)
                VALUES (?, ?, 'Default', ?)
                """, arguments: [environmentID, projectID, now])
            try db.execute(sql: "INSERT INTO config (key, value) VALUES ('active_project_id', ?)",
                           arguments: [projectID])
        }
        // Immediate foreign-key checks: dropping children before parents
        // needs no database-wide foreign_key_check, so legacy rows that are
        // kept can never make this migration, and therefore opening, fail.
        migrator.registerMigration(dropLegacyTablesIdentifier, foreignKeyChecks: .immediate) { db in
            // Recheck the authoritative state inside the migration transaction.
            guard try opening(db) == .baseline else { throw VaultBootstrapError.invalidState }
            // When the legacy tables may hold user data, every table and row
            // stays untouched; GRDB still records this migration as applied.
            if try legacyTablesHoldNoUserData(db) { try dropLegacyTables(db) }
        }
        return migrator
    }

    /// True only when the legacy tables hold nothing beyond the Default seed
    /// written by the legacy schema (and by the baseline): no secret, secret
    /// value or activity row; at most one project, named `Default` with the
    /// seed's active environment and icon; and at most that project's single
    /// `Default` environment without a color. Anything else is kept.
    static func legacyTablesHoldNoUserData(_ db: Database) throws -> Bool {
        for table in ["secrets", "secret_values", "activity_log"] {
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)") == 0 else {
                return false
            }
        }
        // Compare storage values exactly: a non-text value never matches.
        func value(_ row: Row, _ column: String) -> DatabaseValue { row[column] }
        let projects = try Row.fetchAll(db, sql: "SELECT id, name, active_environment, icon FROM projects")
        let environments = try Row.fetchAll(db, sql: "SELECT project_id, name, color FROM environments")
        guard let project = projects.first else { return environments.isEmpty }
        guard projects.count == 1,
              value(project, "name") == "Default".databaseValue,
              value(project, "active_environment") == "Default".databaseValue,
              value(project, "icon") == "folder".databaseValue else { return false }
        guard let environment = environments.first else { return true }
        return environments.count == 1
            && value(environment, "project_id") == value(project, "id")
            && value(environment, "name") == "Default".databaseValue
            && value(environment, "color").isNull
    }

    static func dropLegacyTables(_ db: Database) throws {
        for table in legacyTables {
            try db.execute(sql: "DROP TABLE \(table.quotedDatabaseIdentifier)")
        }
    }

    /// `.current` libraries are at both AskKey identifiers, with the legacy
    /// tables either dropped or kept because they may hold user data.
    enum Opening: Equatable { case baseline, legacyV15, current }

    static func opening(_ db: Database) throws -> Opening {
        guard try db.tableExists("grdb_migrations") else {
            throw VaultBootstrapError.unsupportedMigrations
        }
        let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        let opening: Opening
        let acceptedSchemas: [Bool] // whether the legacy tables are dropped
        if identifiers == [baselineIdentifier] { (opening, acceptedSchemas) = (.baseline, [false]) }
        else if identifiers == legacyIdentifiers { (opening, acceptedSchemas) = (.legacyV15, [false]) }
        else if identifiers == currentIdentifiers { (opening, acceptedSchemas) = (.current, [true, false]) }
        else { throw VaultBootstrapError.unsupportedMigrations }

        let schema = try normalizedSchema(db)
        guard try acceptedSchemas.contains(where: { try expectedSchema(legacyTablesDropped: $0) == schema }) else {
            throw VaultBootstrapError.schemaMismatch
        }
        return opening
    }

    /// Built directly rather than by running the full migrator, because
    /// the drop migration itself calls `opening`.
    private static func expectedSchema(legacyTablesDropped: Bool) throws -> [String] {
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try migrator().migrate(expected, upTo: baselineIdentifier)
        return try expected.write { db in
            if legacyTablesDropped { try dropLegacyTables(db) }
            return try normalizedSchema(db)
        }
    }

    static func adoptLegacyV15(_ db: Database, validation: (Database) throws -> Void = { _ in }) throws {
        // The caller holds the write transaction. Recheck its authoritative state.
        let state = try opening(db)
        try validation(db)
        if state == .legacyV15 {
            try db.execute(sql: "DELETE FROM grdb_migrations")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                           arguments: [baselineIdentifier])
        }
    }

    static func normalizedSchema(_ db: Database) throws -> [String] {
        try Row.fetchAll(db, sql: """
            SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name
            """).map { row in
                let type: String = row["type"]
                let name: String = row["name"]
                let table: String = row["tbl_name"]
                let sql: String? = row["sql"]
                return [type, name, table, sql.map(normalizeSQL) ?? "\u{2}"].joined(separator: "\u{0}")
            }
    }

    // Ignore formatting outside quoted tokens; never normalize literal values.
    static func normalizeSQL(_ sql: String) -> String {
        let characters = Array(sql)
        var tokens: [String] = []
        var word = ""
        var index = 0
        func flushWord() {
            if !word.isEmpty { tokens.append(word.lowercased()); word = "" }
        }
        while index < characters.count {
            let character = characters[index]
            if character == "'" || character == "\"" || character == "`" || character == "[" {
                flushWord()
                let delimiter: Character = character == "[" ? "]" : character
                var quoted = String(character)
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    quoted.append(next)
                    index += 1
                    if next == delimiter {
                        if index < characters.count, characters[index] == delimiter {
                            quoted.append(characters[index])
                            index += 1
                        } else { break }
                    }
                }
                tokens.append(quoted)
                continue
            } else if character.isLetter || character.isNumber || character == "_" || character == "$" {
                word.append(character)
            } else {
                flushWord()
                if !character.isWhitespace { tokens.append(String(character)) }
            }
            index += 1
        }
        flushWord()
        return tokens.joined(separator: "\u{1}")
    }
}

extension VaultStore {
    func migrate() throws { try CurrentLibrarySchema.migrator().migrate(db) }
}
