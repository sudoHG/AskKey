enum FrozenAgentTextMutation {
    case create(CredentialRecord)
    case modify(CredentialRecord, expectedUpdatedAt: String)
    case delete(credentialID: String, expectedUpdatedAt: String, deletedAt: String)
}
