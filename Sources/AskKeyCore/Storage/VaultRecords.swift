import Foundation
import GRDB

// MARK: - Records

struct ConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "config"
    var key: String
    var value: String
}

struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "projects"
    var id: String
    var name: String
    var activeEnvironment: String?
    var icon: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case activeEnvironment = "active_environment"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EnvironmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "environments"
    var id: String
    var projectId: String
    var name: String
    var color: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case name, color
        case createdAt = "created_at"
    }
}

struct SecretRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "secrets"
    var id: String
    var projectId: String
    var name: String
    var description: String?
    var icon: String?
    var category: String
    var createdAt: String
    var updatedAt: String
    var agentAccess: String = AgentAccessPolicy.allowed.rawValue

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case name, description, icon, category
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case agentAccess = "agent_access"
    }
}

struct SecretValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "secret_values"
    var id: String
    var secretId: String
    var environmentId: String?
    var encryptedValue: Data
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case secretId = "secret_id"
        case environmentId = "environment_id"
        case encryptedValue = "encrypted_value"
        case updatedAt = "updated_at"
    }
}

struct CredentialRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "credentials"
    var id: String
    var nameIndex: Data
    var encryptedDisplayName: Data
    var encryptedPayload: Data
    var encryptedUsageInstructions: Data
    var encryptedPrivateNotes: Data
    var encryptedGroupName: Data?
    var encryptedEnvironmentVariable: Data?
    var payloadKind: String
    var permission: String
    var expiresAt: String?
    var createdAt: String
    var updatedAt: String
    var encryptedOriginalFilename: Data?
    var byteSize: Int?
    var contentDigest: Data?
    var deletedAt: String?
    var authenticationTag: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case nameIndex = "name_index"
        case encryptedDisplayName = "encrypted_display_name"
        case encryptedPayload = "encrypted_payload"
        case encryptedUsageInstructions = "encrypted_usage_instructions"
        case encryptedPrivateNotes = "encrypted_private_notes"
        case encryptedGroupName = "encrypted_group_name"
        case encryptedEnvironmentVariable = "encrypted_environment_variable"
        case payloadKind = "payload_kind"
        case permission
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case encryptedOriginalFilename = "encrypted_original_filename"
        case byteSize = "byte_size"
        case contentDigest = "content_digest"
        case deletedAt = "deleted_at"
        case authenticationTag = "authentication_tag"
    }
}

struct AgentWriteOperationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_write_operations"
    var operationId: String
    var payloadDigest: String
    var credentialId: String
    var operation: String
    var committedAt: String
    var requestId: String
    var capabilityDigest: String
    var resultDigest: String? = nil

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case payloadDigest = "payload_digest"
        case credentialId = "credential_id"
        case operation
        case committedAt = "committed_at"
        case requestId = "request_id"
        case capabilityDigest = "capability_digest"
        case resultDigest = "result_digest"
    }
}

struct CredentialAccessRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "credential_access_records"
    var id: String
    var encryptedRecord: Data

    enum CodingKeys: String, CodingKey {
        case id
        case encryptedRecord = "encrypted_record"
    }
}

struct ActivityLogRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "activity_log"
    var id: String
    var secretName: String
    var projectName: String
    var environmentName: String
    var source: String
    var accessedAt: String
    var agent: String?
    var peerTeam: String?
    var action: String

    enum CodingKeys: String, CodingKey {
        case id
        case secretName = "secret_name"
        case projectName = "project_name"
        case environmentName = "environment_name"
        case source
        case accessedAt = "accessed_at"
        case agent
        case peerTeam = "peer_team"
        case action
    }
}
