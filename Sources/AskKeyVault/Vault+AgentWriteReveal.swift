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
        _ = try currentFrozenWriteRecord(frozen)
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

    private func currentFrozenWriteRecord(_ frozen: FrozenAgentTextWrite) throws -> CredentialRecord? {
        guard let expected = frozen.beforeStateDigest else { return nil }
        guard let record = try store.fetchCredential(id: frozen.approvalRequest.credentialID),
              try record.agentWriteStateDigest() == expected else { throw VaultError.credentialChanged }
        return record
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
            let current = try currentFrozenWriteRecord(frozen)
            let before: [CredentialComponentInput]
            let after: [CredentialComponentInput]
            switch frozen.mutation {
            case .create(let record):
                before = []
                after = try credentialComponents(from: record, key: key)
            case .modify(let record, _):
                let touched = Set((frozen.summary?.after.filter { $0.valueChanged == true }.map(\.name) ?? [])
                    .map(CredentialName.normalized) + frozen.componentChanges.map { CredentialName.normalized($0.name) })
                // Explicit authenticated reveal opens the stored payload for
                // display only. Untouched values never reach the reveal view.
                before = try current.map { try touched.isEmpty ? [] : credentialComponents(from: $0, key: key)
                    .filter { touched.contains(CredentialName.normalized($0.name)) } } ?? []
                if !frozen.componentChanges.isEmpty {
                    after = frozen.componentChanges.compactMap { if case .upsert(let input) = $0 { return input }; return nil }
                } else {
                    after = touched.isEmpty ? [] : try credentialComponents(from: record, key: key)
                }
            case .delete:
                before = try current.map { try credentialComponents(from: $0, key: key) } ?? []
                after = []
            }
            return .init(credentialName: frozen.approvalRequest.credentialName ?? "", operation: frozen.approvalRequest.operation,
                before: before, after: after)
        }
    }
}
