import CryptoKit
import Foundation
import AskKeyBroker

struct FrozenAgentTextWrite {
    let operationID: String
    let digest: String
    let approvalRequest: BrokerApprovalOperationRequest
    let credentialExpiresAt: Date?
    let mutation: FrozenAgentTextMutation
    var beforeRecord: CredentialRecord? = nil
    var summary: BrokerCredentialWriteSummary? = nil
    var groupAssignment: String? = nil
    var beforeStateDigest: String? = nil
    var componentChanges: [FrozenAgentComponentChange] = []
    var permitsLegacyTextReveal = false
}

enum FrozenAgentComponentChange {
    case upsert(CredentialComponentInput)
    case remove(String)

    var name: String {
        switch self {
        case .upsert(let component): return component.name
        case .remove(let name): return name
        }
    }

    static func applying<Component>(_ changes: [Self], to components: [Component],
        name: (Component) -> String, replacement: (CredentialComponentInput) -> Component) throws -> [Component] {
        var result = components
        var touched = Set<String>()
        for change in changes {
            let normalized = CredentialName.normalized(try CredentialName.displayName(from: change.name))
            guard touched.insert(normalized).inserted else { throw BrokerApprovalError.invalidRequest }
            let index = result.firstIndex { CredentialName.normalized(name($0)) == normalized }
            switch change {
            case .upsert(let input):
                if let index { result[index] = replacement(input) } else { result.append(replacement(input)) }
            case .remove:
                guard let index else { throw BrokerApprovalError.invalidRequest }
                result.remove(at: index)
            }
        }
        return result
    }
}

extension CredentialRecord {
    func agentWriteStateDigest() throws -> String {
        // Canonical JSON covers the complete authenticated stored row, including
        // every ciphertext, metadata ciphertext, policy, timestamps and MAC.
        // Persistence-only flags are excluded by CredentialRecord.CodingKeys.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Vault.componentDigest(Data("AskKey agent write stored state v1\0".utf8) + (try encoder.encode(self)))
    }
}
