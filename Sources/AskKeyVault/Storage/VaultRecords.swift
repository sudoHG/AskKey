import Foundation
import GRDB

// MARK: - Records

struct ConfigRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "config"
    var key: String
    var value: String
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
    // Nil is omitted by Codable, preserving authentication of pre-metadata rows.
    var encryptedComponentMetadata: Data? = nil
    // Persistence-only compatibility with an upgrade that rolled back to 0002.
    // This flag never participates in the authenticated Codable representation.
    var includesComponentMetadataColumn = true

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["name_index"] = nameIndex
        container["encrypted_display_name"] = encryptedDisplayName
        container["encrypted_payload"] = encryptedPayload
        container["encrypted_usage_instructions"] = encryptedUsageInstructions
        container["encrypted_private_notes"] = encryptedPrivateNotes
        container["encrypted_group_name"] = encryptedGroupName
        container["encrypted_environment_variable"] = encryptedEnvironmentVariable
        container["payload_kind"] = payloadKind
        container["permission"] = permission
        container["expires_at"] = expiresAt
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
        container["encrypted_original_filename"] = encryptedOriginalFilename
        container["byte_size"] = byteSize
        container["content_digest"] = contentDigest
        container["deleted_at"] = deletedAt
        container["authentication_tag"] = authenticationTag
        if includesComponentMetadataColumn { container["encrypted_component_metadata"] = encryptedComponentMetadata }
    }

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
        case encryptedComponentMetadata = "encrypted_component_metadata"
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
