CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
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
