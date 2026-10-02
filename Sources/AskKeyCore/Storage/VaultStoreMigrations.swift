import Foundation
import GRDB

enum CurrentLibrarySchema {
    static let baselineIdentifier = "askkey-0001-baseline"
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

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(baselineIdentifier) { db in
            try db.execute(sql: baselineSQL)
            // Retain the Default seed required by the still-supported queries.
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
        return migrator
    }

    enum Opening: Equatable { case baseline, legacyV15 }

    static func opening(_ db: Database) throws -> Opening {
        guard try db.tableExists("grdb_migrations") else {
            throw VaultBootstrapError.unsupportedMigrations
        }
        let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        let opening: Opening
        if identifiers == [baselineIdentifier] { opening = .baseline }
        else if identifiers == legacyIdentifiers { opening = .legacyV15 }
        else { throw VaultBootstrapError.unsupportedMigrations }

        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try migrator().migrate(expected)
        guard try normalizedSchema(db) == expected.read({ try normalizedSchema($0) }) else {
            throw VaultBootstrapError.schemaMismatch
        }
        return opening
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
