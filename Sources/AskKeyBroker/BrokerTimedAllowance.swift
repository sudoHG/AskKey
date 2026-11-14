import Foundation

/// Trusted App-only metadata. Never accepted from a Broker client or sent over RPC.
public struct BrokerGroupAllowanceSnapshot: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public let credentialID: String
        public let name: String
        public let metadataDigest: String
        public let expiresAt: Date?

        public init(credentialID: String, name: String, metadataDigest: String, expiresAt: Date? = nil) {
            self.credentialID = credentialID
            self.name = name
            self.metadataDigest = metadataDigest
            self.expiresAt = expiresAt
        }
    }

    public let groupName: String
    public let members: [Member]

    public init(groupName: String, members: [Member]) {
        self.groupName = groupName
        self.members = members
    }

    public var earliestExpiry: Date? { members.compactMap(\.expiresAt).min() }
}

/// One revocable grant, including single-credential grants.
public struct BrokerTimedAllowance: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let groupName: String?
    public var members: [BrokerGroupAllowanceSnapshot.Member]
    public let expiresAt: Date
    /// The paired device that granted it remotely (ADR 0014); nil when it was
    /// granted on this Mac.
    public let approvingDeviceName: String?

    public init(id: UUID = UUID(), groupName: String? = nil,
                members: [BrokerGroupAllowanceSnapshot.Member], expiresAt: Date,
                approvingDeviceName: String? = nil) {
        self.id = id
        self.groupName = groupName
        self.members = members
        self.expiresAt = expiresAt
        self.approvingDeviceName = approvingDeviceName
    }
}
