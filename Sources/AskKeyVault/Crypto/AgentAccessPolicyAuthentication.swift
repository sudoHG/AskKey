import CryptoKit
import Foundation

enum AgentAccessPolicyAuthentication {
    private struct Envelope: Codable {
        let policy: AgentAccessPolicy
        let authenticationTag: Data
    }

    static func seal(_ policy: AgentAccessPolicy, using vaultKey: SymmetricKey) throws -> String {
        try policy.validate()
        let tag = HMAC<SHA256>.authenticationCode(
            for: try authenticatedBytes(policy), using: authenticationKey(vaultKey)
        )
        let data = try encoder().encode(Envelope(policy: policy, authenticationTag: Data(tag)))
        return String(decoding: data, as: UTF8.self)
    }

    static func open(_ value: String, using vaultKey: SymmetricKey) throws -> AgentAccessPolicy {
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(value.utf8))
        try envelope.policy.validate()
        guard envelope.authenticationTag.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(
                envelope.authenticationTag,
                authenticating: try authenticatedBytes(envelope.policy),
                using: authenticationKey(vaultKey)
              ) else {
            throw AgentAccessPolicyError.invalidPolicy
        }
        return envelope.policy
    }

    private static func authenticatedBytes(_ policy: AgentAccessPolicy) throws -> Data {
        Data("AskKey agent access policy v1\0".utf8) + (try encoder().encode(policy))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func authenticationKey(_ vaultKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: vaultKey,
            salt: Data(),
            info: Data("AskKey agent access policy authentication v1".utf8),
            outputByteCount: 32
        )
    }
}
