import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func revealAgentTextWrite(
        operationID: String,
        requestID: String,
        capability: String,
        using authenticator: ManagementAuthenticator
    ) throws -> AgentTextWriteAction {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        guard let frozen = agentTextWrites.entry(operationID: operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        let state = try approvalRequests.status(
            requestID: requestID,
            capability: capability,
            operationRequest: frozen.approvalRequest
        )
        guard state == .pending || state == .approved else {
            throw BrokerApprovalError.invalidDecision
        }
        let key = try requireKey()
        switch frozen.mutation {
        case .create(let record):
            return .create(
                name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                value: try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            )
        case .modify(let record, _):
            return .modify(
                name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                value: try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            )
        case .delete(let credentialID, _, _):
            guard let record = try store.fetchCredential(id: credentialID) else {
                throw VaultError.credentialNotFound(credentialID)
            }
            return .delete(name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key))
        }
    }

    private func activeFrozenWrite(operationID: String, requestID: String, capability: String) throws -> FrozenAgentTextWrite {
        guard let frozen = agentTextWrites.entry(operationID: operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        let state = try approvalRequests.status(requestID: requestID, capability: capability,
            operationRequest: frozen.approvalRequest)
        guard state == .pending || state == .approved else { throw BrokerApprovalError.invalidDecision }
        return frozen
    }

    public func frozenAgentWriteSummary(operationID: String, requestID: String, capability: String) throws -> BrokerCredentialWriteSummary {
        let frozen = try activeFrozenWrite(operationID: operationID, requestID: requestID, capability: capability)
        guard let summary = frozen.summary else { throw BrokerApprovalError.invalidRequest }
        return summary
    }

    public func revealFrozenCredentialWrite(operationID: String, requestID: String, capability: String,
        using authenticator: ManagementAuthenticator) throws -> FrozenCredentialWrite {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        return try agentTextWrites.synchronized {
            let frozen = try activeFrozenWrite(operationID: operationID, requestID: requestID, capability: capability)
            let key = try requireKey()
            let before = try frozen.beforeRecord.map { try credentialComponents(from: $0, key: key) } ?? []
            let after: [CredentialComponentInput]
            switch frozen.mutation {
            case .create(let record), .modify(let record, _): after = try credentialComponents(from: record, key: key)
            case .delete: after = []
            }
            return .init(credentialName: frozen.approvalRequest.credentialName ?? "", operation: frozen.approvalRequest.operation,
                before: before, after: after)
        }
    }
}
