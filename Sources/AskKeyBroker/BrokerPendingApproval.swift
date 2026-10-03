import Foundation

/// App-only projection used to render the direct confirmation surface. It carries
/// request metadata and the opaque decision capability, never credential values.
public struct BrokerPendingApproval: Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let request: BrokerApprovalOperationRequest
    public let expiresAt: Date?
    /// Vault-derived display metadata; never part of the operation binding.
    public let trustedCredentialName: String?

    public var displayCredentialName: String {
        trustedCredentialName ?? request.credentialName ?? request.targetID
    }

    public init(
        requestID: String,
        capability: String,
        request: BrokerApprovalOperationRequest,
        expiresAt: Date? = nil,
        trustedCredentialName: String? = nil
    ) {
        self.requestID = requestID
        self.capability = capability
        self.request = request
        self.expiresAt = expiresAt
        self.trustedCredentialName = trustedCredentialName
    }
}
