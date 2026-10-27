import AskKeyBroker

public struct FrozenCredentialWrite: Equatable, Sendable {
    public let credentialName: String
    public let operation: BrokerApprovalOperation
    /// Explicit authenticated display only. Modifications omit untouched
    /// components from both sides; no revealed values are cached in the write.
    public let before: [CredentialComponentInput]
    public let after: [CredentialComponentInput]
}
