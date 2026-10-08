import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func commitAgentTextWrite(
        _ request: AgentTextWriteRequest,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult {
        let operation: CredentialAccessEvent.Operation
        switch request.action {
        case .create, .createBundle: operation = .create
        case .modify, .modifyBundle: operation = .modify
        case .delete: operation = .delete
        }
        var credentialID = agentTextWrites.entry(operationID: request.operationID)?
            .approvalRequest.credentialID
        var succeeded = false
        defer {
            recordCredentialAccess(.init(
                timestamp: currentDate,
                credentialID: credentialID,
                operation: operation,
                result: succeeded ? .allowed : .failed,
                callerHint: request.callerName,
                declaredPurpose: request.callerPurpose
            ))
        }
        let wasPaused = try agentAccessGate.beginExclusiveAgentChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let result = try agentTextWrites.synchronized {
            try commitAgentTextWriteSynchronized(
                request,
                requestID: requestID,
                capability: capability
            )
        }
        credentialID = result.credentialID
        fileDeliveryManager.revoke(credentialID: result.credentialID)
        succeeded = true
        return result
    }

    private func commitAgentTextWriteSynchronized(
        _ request: AgentTextWriteRequest,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult {
        let digest = try agentTextWriteDigest(request)
        if let committed = try completedAgentTextWrite(
            operationID: request.operationID,
            digest: digest,
            requestID: requestID,
            capability: capability
        ) {
            return committed
        }
        guard let frozen = agentTextWrites.entry(operationID: request.operationID) else {
            throw BrokerApprovalError.requestNotFound
        }
        guard frozen.digest == digest else {
            throw BrokerApprovalError.payloadMismatch
        }
        if let expiresAt = frozen.credentialExpiresAt, expiresAt <= currentDate {
            cancelAgentWrites(credentialID: frozen.approvalRequest.credentialID)
            throw VaultError.credentialUnavailable
        }
        do {
            let result = try approvalRequests.consumeApproved(
                requestID: requestID,
                capability: capability,
                operationRequest: frozen.approvalRequest
            ) {
                try store.commitAgentTextWrite(
                    frozen,
                    requestID: requestID,
                    capabilityDigest: agentTextWriteCapabilityDigest(capability),
                    clock: { currentDate },
                    credentialGroupsKey: try requireKey()
                )
            }
            agentTextWrites.remove(operationID: request.operationID)
            brokerRequests.cancelPending(credentialID: result.credentialID)
            approvalRequests.cancelPending(credentialID: result.credentialID)
            notifySnapshotRelevantChange()
            return result
        } catch VaultError.credentialUnavailable {
            cancelAgentWrites(credentialID: frozen.approvalRequest.credentialID)
            throw VaultError.credentialUnavailable
        } catch BrokerApprovalError.alreadyConsumed {
            guard let committed = try completedAgentTextWrite(
                operationID: request.operationID,
                digest: digest,
                requestID: requestID,
                capability: capability
            ) else {
                throw BrokerApprovalError.alreadyConsumed
            }
            return committed
        } catch {
            do {
                let state = try approvalRequests.status(requestID: requestID, capability: capability)
                if state != .pending, state != .approved {
                    agentTextWrites.remove(operationID: request.operationID)
                }
            } catch {
                agentTextWrites.remove(operationID: request.operationID)
            }
            throw error
        }
    }

    private func cancelAgentWrites(credentialID: String) {
        brokerRequests.cancelPending(credentialID: credentialID)
        approvalRequests.cancelPending(credentialID: credentialID)
    }

    private func completedAgentTextWrite(
        operationID: String,
        digest: String,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult? {
        guard let committed = try store.fetchAgentWriteOperation(operationID: operationID) else {
            return nil
        }
        guard committed.payloadDigest == digest else { throw BrokerApprovalError.payloadMismatch }
        guard committed.requestId == requestID,
              committed.capabilityDigest == agentTextWriteCapabilityDigest(capability) else {
            throw BrokerApprovalError.requestNotFound
        }
        return .init(operationID: committed.operationId, credentialID: committed.credentialId)
    }

    private func agentTextWriteCapabilityDigest(_ capability: String) -> String {
        SHA256.hash(data: Data(capability.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
