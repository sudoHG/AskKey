import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    func requestAgentOrganization(_ request: AgentTextWriteRequest) throws -> AgentTextWriteRequestOutcome {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try agentOrganizations.synchronized {
            let digest = try agentTextWriteDigest(request)
            if let committed = try store.fetchAgentWriteOperation(operationID: request.operationID) {
                guard committed.payloadDigest == digest, committed.operation == BrokerApprovalOperation.organize.rawValue else {
                    throw BrokerApprovalError.payloadMismatch
                }
                return .completed(.init(operationID: request.operationID, credentialID: ""))
            }
            if let ticket = try approvalRequests.terminalRetransmission(operationID: request.operationID, payloadDigest: digest) {
                return .submitted(organizationSubmission(request.operationID, ticket: ticket))
            }
            let existing = agentOrganizations.entry(operationID: request.operationID)
            let frozen = try existing ?? freezeAgentOrganization(request, digest: digest, key: requireKey())
            guard frozen.digest == digest else { throw BrokerApprovalError.payloadMismatch }
            try agentOrganizations.store(frozen)
            do {
                let ticket = try approvalRequests.submit(frozen.approvalRequest,
                    trustedCredentialDeadline: frozen.credentialExpiresAt.map { .expiresAt($0) } ?? .none)
                return .submitted(organizationSubmission(request.operationID, ticket: ticket))
            } catch {
                if existing == nil { agentOrganizations.remove(operationID: request.operationID) }
                throw error
            }
        }
    }

    func cancelAgentOrganization(operationID: String, requestID: String, capability: String) throws -> BrokerRequestState {
        guard let frozen = agentOrganizations.entry(operationID: operationID) else { throw BrokerApprovalError.requestNotFound }
        return try approvalRequests.cancel(requestID: requestID, capability: capability, operationRequest: frozen.approvalRequest)
    }

    public func frozenAgentOrganizationSummary(operationID: String, requestID: String,
                                               capability: String) throws -> BrokerOrganizationSummary {
        guard let frozen = agentOrganizations.entry(operationID: operationID) else { throw BrokerApprovalError.requestNotFound }
        _ = try approvalRequests.status(requestID: requestID, capability: capability, operationRequest: frozen.approvalRequest)
        return frozen.summary
    }

    func commitAgentOrganization(_ request: AgentTextWriteRequest, requestID: String,
                                 capability: String) throws -> AgentTextWriteResult {
        let wasPaused = try agentAccessGate.beginExclusiveAgentChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        return try agentOrganizations.synchronized {
            let digest = try agentTextWriteDigest(request)
            let capabilityDigest = Self.componentDigest(Data(capability.utf8))
            if let receipt = try store.fetchAgentWriteOperation(operationID: request.operationID) {
                guard receipt.payloadDigest == digest, receipt.operation == BrokerApprovalOperation.organize.rawValue else {
                    throw BrokerApprovalError.payloadMismatch
                }
                guard receipt.requestId == requestID, receipt.capabilityDigest == capabilityDigest else {
                    throw BrokerApprovalError.requestNotFound
                }
                return .init(operationID: request.operationID, credentialID: "")
            }
            guard let frozen = agentOrganizations.entry(operationID: request.operationID) else { throw BrokerApprovalError.requestNotFound }
            guard frozen.digest == digest else { throw BrokerApprovalError.payloadMismatch }
            var succeeded = false
            defer { recordAgentOrganizationAccess(frozen.approvalRequest, result: succeeded ? .allowed : .failed) }
            let result = try approvalRequests.consumeApproved(requestID: requestID, capability: capability,
                operationRequest: frozen.approvalRequest) {
                try store.commitAgentOrganization(frozen, requestID: requestID, capabilityDigest: capabilityDigest,
                    key: requireKey(), clock: { currentDate })
            }
            succeeded = true
            for id in frozen.approvalRequest.organizationCredentialIDs ?? [] {
                brokerRequests.cancelPending(credentialID: id)
                approvalRequests.cancelPending(credentialID: id)
                fileDeliveryManager.revoke(credentialID: id)
            }
            notifySnapshotRelevantChange()
            return result
        }
    }

    func recordAgentOrganizationAccess(_ request: BrokerApprovalOperationRequest, result: CredentialAccessEvent.Result) {
        let ids = request.organizationCredentialIDs ?? []
        let targets: [String?] = ids.isEmpty ? [nil] : ids.map { Optional($0) }
        for id in targets {
            recordCredentialAccess(.init(timestamp: currentDate, credentialID: id, operation: .modify, result: result,
                callerHint: request.callerName, declaredPurpose: request.callerPurpose))
        }
    }

    private func organizationSubmission(_ operationID: String, ticket: BrokerApprovalTicket) -> AgentTextWriteSubmission {
        .init(operationID: operationID, requestID: ticket.requestID, capability: ticket.capability,
            state: ticket.state, retryCount: ticket.retryCount)
    }
}
