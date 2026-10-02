import Foundation

public enum CredentialPermission: String, Codable, Equatable, Sendable, CaseIterable {
    case allowed
    case ask
    case hidden

    public var managementLabel: String {
        switch self {
        case .allowed: return CredentialManagementCopy.allowed
        case .ask: return CredentialManagementCopy.ask
        case .hidden: return CredentialManagementCopy.hidden
        }
    }
}

public enum CredentialPayloadKind: String, Codable, Equatable, Sendable {
    case text
    case file
    case bundle
}

/// Caller-provided display context. These values are never authorization inputs.
public struct BrokerCallerClaim: Equatable, Sendable {
    public let name: String?
    public let path: String?
    public let signature: String?

    public init(name: String? = nil, path: String? = nil, signature: String? = nil) {
        self.name = name
        self.path = path
        self.signature = signature
    }
}

public enum AgentCredentialOperation: Equatable, Sendable {
    case read
    case modify
    case delete
}

public enum AgentCredentialAuthorization: Equatable, Sendable {
    case allowed
    case requiresApproval
}

/// Encrypted vNext data prepared in memory. Nothing in this type is persisted by
/// the migration preview.
public struct StagedCredential: Equatable, Sendable {
    public let id: String
    public let nameIndex: Data
    public let encryptedDisplayName: Data
    public let encryptedPayload: Data
    public let encryptedUsageInstructions: Data
    public let encryptedPrivateNotes: Data
    public let encryptedGroupName: Data?
    public let payloadKind: CredentialPayloadKind
    public let permission: CredentialPermission
    public var encryptedEnvironmentVariable: Data? = nil
    public var encryptedOriginalFilename: Data? = nil
    public var byteSize: Int? = nil
    public var contentDigest: Data? = nil
    public var expiresAt: String? = nil
    public var createdAt: String? = nil
    public var updatedAt: String? = nil
    public var deletedAt: String? = nil
}

public struct LegacyCredentialSource: Equatable, Sendable {
    public let projectName: String
    public let environmentName: String
    public let secretID: String
}

public struct MigrationProposal: Equatable, Sendable {
    public let displayName: String
    public let normalizedName: String
    public let permission: CredentialPermission
    public let suggestedGroupName: String?
    public let source: LegacyCredentialSource
    public let stagedCredential: StagedCredential
    /// Historical permissions have no authenticated provenance. The review
    /// explicitly shows their replacement with Ask before committing.
    public var originalPermission: CredentialPermission? = nil
}

public struct MigrationNameConflict: Equatable, Sendable {
    public let normalizedName: String
    public let displayNames: [String]
    public let sources: [LegacyCredentialSource]
}

public struct MigrationStatistics: Equatable, Sendable {
    public let credentials: Int
    public let conflicts: Int

    public init(credentials: Int, conflicts: Int) {
        self.credentials = credentials
        self.conflicts = conflicts
    }
}

public struct MigrationPreview: Equatable, Sendable {
    public let proposals: [MigrationProposal]
    public let conflicts: [MigrationNameConflict]
    public var sourceFingerprint: Data? = nil
    public var groupNames: [String] = []
    public var accessRecords: [StagedCredentialAccessRecord] = []

    public var requiresAuthorizationReview: Bool {
        proposals.contains { $0.originalPermission != nil }
    }

    public var statistics: MigrationStatistics {
        .init(credentials: proposals.count, conflicts: conflicts.count)
    }

    public var canCommit: Bool { conflicts.isEmpty }
}

public struct StagedCredentialAccessRecord: Equatable, Sendable {
    public let id: String
    public let encryptedRecord: Data
}
