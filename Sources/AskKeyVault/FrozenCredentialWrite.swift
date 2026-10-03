import AskKeyBroker

public struct FrozenCredentialWrite: Equatable, Sendable {
    public let credentialName: String
    public let operation: BrokerApprovalOperation
    public let before: [CredentialComponentInput]
    public let after: [CredentialComponentInput]
}
