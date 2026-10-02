import Foundation
import GRDB

extension VaultStore {
    func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            let now = iso8601()

            try db.create(table: "config") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            try db.create(table: "projects") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("path", .text)
                t.column("active_environment", .text)
                t.column("icon", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "environments") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("created_at", .text).notNull()
                t.uniqueKey(["project_id", "name"])
            }

            try db.create(table: "secrets") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text).notNull().references("projects", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("icon", .text)
                t.column("category", .text).notNull().defaults(to: SecretCategory.secret.rawValue)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.uniqueKey(["project_id", "name"])
            }

            try db.create(table: "secret_values") { t in
                t.column("id", .text).primaryKey()
                t.column("secret_id", .text).notNull().references("secrets", onDelete: .cascade)
                t.column("environment_id", .text).references("environments", onDelete: .cascade)
                t.column("encrypted_value", .blob).notNull()
                t.column("updated_at", .text).notNull()
                t.uniqueKey(["secret_id", "environment_id"])
            }

            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS secret_values_unique_default_environment
                ON secret_values(secret_id)
                WHERE environment_id IS NULL
            """)

            let defaultProjectId = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO projects (id, name, path, active_environment, icon, created_at, updated_at)
                VALUES (?, 'Default', NULL, NULL, 'folder', ?, ?)
            """, arguments: [defaultProjectId, now, now])

            try db.execute(sql: "INSERT INTO config (key, value) VALUES ('active_project_id', ?)",
                           arguments: [defaultProjectId])
        }

        // No "v2": an early migration was dropped before release and the numbers
        // were never renumbered. GRDB keys migrations by string, so the gap is
        // harmless — v1 then v3 apply in registration order (L5).
        migrator.registerMigration("v3") { db in
            try db.create(table: "activity_log", options: .ifNotExists) { t in
                t.column("id", .text).primaryKey()
                t.column("secret_name", .text).notNull()
                t.column("project_name", .text).notNull()
                t.column("environment_name", .text).notNull()
                t.column("source", .text).notNull()
                t.column("accessed_at", .text).notNull()
            }
        }

        migrator.registerMigration("v4") { db in
            let now = iso8601()
            let projects = try ProjectRecord.fetchAll(db)

            for project in projects {
                let defaultEnvironment: EnvironmentRecord
                if let existing = try EnvironmentRecord
                    .filter(Column("project_id") == project.id && Column("name") == "Default")
                    .fetchOne(db) {
                    defaultEnvironment = existing
                } else {
                    defaultEnvironment = EnvironmentRecord(
                        id: UUID().uuidString,
                        projectId: project.id,
                        name: "Default",
                        color: nil,
                        createdAt: now
                    )
                    try defaultEnvironment.insert(db)
                }

                try db.execute(sql: """
                    UPDATE secret_values
                    SET environment_id = ?
                    WHERE environment_id IS NULL
                      AND secret_id IN (SELECT id FROM secrets WHERE project_id = ?)
                """, arguments: [defaultEnvironment.id, project.id])

                if project.activeEnvironment == nil {
                    try db.execute(sql: """
                        UPDATE projects
                        SET active_environment = ?, updated_at = ?
                        WHERE id = ?
                    """, arguments: [defaultEnvironment.name, now, project.id])
                }
            }
        }

        migrator.registerMigration("v5") { db in
            try db.alter(table: "secrets") { t in
                t.add(column: "agent_access", .text)
                    .notNull()
                    .defaults(to: AgentAccessPolicy.allowed.rawValue)
            }
        }

        migrator.registerMigration("v6") { db in
            try db.alter(table: "activity_log") { t in
                t.add(column: "agent", .text)
                t.add(column: "action", .text)
                    .notNull()
                    .defaults(to: ActivityLogEntry.Action.read.rawValue)
            }
        }

        // ADR 0019: the Developer ID team of the genuine signed binary that
        // brokered the read, when verified. Nullable/additive — existing rows
        // and app-local/dev reads stay nil.
        migrator.registerMigration("v7") { db in
            try db.alter(table: "activity_log") { t in
                t.add(column: "peer_team", .text)
            }
        }

        migrator.registerMigration("v8") { db in
            try db.create(table: "credentials") { t in
                t.column("id", .text).primaryKey()
                t.column("name_index", .blob).notNull().unique()
                t.column("encrypted_display_name", .blob).notNull()
                t.column("encrypted_payload", .blob).notNull()
                t.column("encrypted_usage_instructions", .blob).notNull()
                t.column("encrypted_private_notes", .blob).notNull()
                t.column("encrypted_group_name", .blob)
                t.column("encrypted_environment_variable", .blob)
                t.column("payload_kind", .text).notNull()
                t.column("permission", .text).notNull()
                t.column("expires_at", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "folder_associations") { t in
                t.column("path", .text).primaryKey()
                t.column("encrypted_suggested_group_name", .blob)
            }
        }

        migrator.registerMigration("v9") { db in
            try db.alter(table: "credentials") { t in
                t.add(column: "encrypted_original_filename", .blob)
                t.add(column: "byte_size", .integer)
                t.add(column: "content_digest", .blob)
            }
        }

        migrator.registerMigration("v10") { db in
            try db.alter(table: "credentials") { t in
                t.add(column: "deleted_at", .text)
            }
            try db.create(table: "agent_write_operations") { t in
                t.column("operation_id", .text).primaryKey()
                t.column("payload_digest", .text).notNull()
                t.column("credential_id", .text).notNull()
                t.column("operation", .text).notNull()
                t.column("committed_at", .text).notNull()
                t.column("request_id", .text).notNull()
                t.column("capability_digest", .text).notNull()
            }
        }

        migrator.registerMigration("v11") { db in
            try db.create(table: "credential_access_records") { t in
                t.column("id", .text).primaryKey()
                t.column("encrypted_record", .blob).notNull()
            }
        }

        migrator.registerMigration("v12-remove-folder-associations") { db in
            try db.drop(table: "folder_associations")
        }

        migrator.registerMigration("v13-remove-project-path") { db in
            try db.alter(table: "projects") { table in
                table.drop(column: "path")
            }
        }

        migrator.registerMigration("v14-authenticated-credentials") { db in
            // Existing rows deliberately remain unsigned. Only the explicit
            // migration acceptance path may import historical unsigned records.
            try db.alter(table: "credentials") { table in
                table.add(column: "authentication_tag", .blob)
            }
        }

        migrator.registerMigration("v15-file-write-receipts") { db in
            try db.alter(table: "agent_write_operations") { table in
                table.add(column: "result_digest", .text)
            }
            try db.create(index: "agent_write_operations_request_id", on: "agent_write_operations", columns: ["request_id"])
        }

        try migrator.migrate(db)
    }
}
