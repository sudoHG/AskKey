import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func requestAgentTextWrite(
        _ request: AgentTextWriteRequest,
        fileResolver: (BrokerComponentFileReference) throws -> BrokerFrozenComponentFile = { _ in
            throw BrokerApprovalError.invalidRequest
        }
    ) throws -> AgentTextWriteRequestOutcome {
        try validateAgentTextWrite(request)
        if case .organize = request.action { return try requestAgentOrganization(request) }
        // Resolve upload capabilities outside the gate/registry locks. Legacy file
        // commit takes the coordinator lock before acquiring the exclusive gate.
        let alreadyFrozen = agentTextWrites.entry(operationID: request.operationID) != nil
        let alreadyCommitted = try store.fetchAgentWriteOperation(operationID: request.operationID) != nil
        var files: [BrokerComponentFileReference: BrokerFrozenComponentFile] = [:]
        if !alreadyFrozen && !alreadyCommitted {
            var totalFileBytes = 0
            for reference in request.componentFileReferences {
                let file = try fileResolver(reference)
                totalFileBytes += file.bytes.count
                guard totalFileBytes <= BrokerFileWriteCoordinator.maximumByteCount else {
                    throw BrokerApprovalError.invalidRequest
                }
                guard file.digest == reference.digest,
                      Self.componentDigest(file.bytes) == reference.digest else {
                    throw BrokerApprovalError.payloadMismatch
                }
                files[reference] = file
            }
        }
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try agentTextWrites.synchronized {
            try requestAgentTextWriteSynchronized(request, files: files)
        }
    }

    private func requestAgentTextWriteSynchronized(
        _ request: AgentTextWriteRequest,
        files: [BrokerComponentFileReference: BrokerFrozenComponentFile]
    ) throws -> AgentTextWriteRequestOutcome {
        try validateAgentTextWrite(request)
        let digest = try agentTextWriteDigest(request)
        if let committed = try store.fetchAgentWriteOperation(operationID: request.operationID) {
            guard committed.payloadDigest == digest else { throw BrokerApprovalError.payloadMismatch }
            return .completed(.init(operationID: committed.operationId, credentialID: committed.credentialId))
        }
        if let ticket = try approvalRequests.terminalRetransmission(
            operationID: request.operationID,
            payloadDigest: digest
        ) {
            return .submitted(submission(operationID: request.operationID, ticket: ticket))
        }
        let key = try requireKey()
        let candidate: FrozenAgentTextWrite
        if let existing = agentTextWrites.entry(operationID: request.operationID) {
            guard existing.digest == digest else { throw BrokerApprovalError.payloadMismatch }
            candidate = existing
        } else {
            candidate = try freezeAgentTextWrite(request, digest: digest, key: key, files: files)
        }
        let reservation = try agentTextWrites.store(candidate)
        do {
            let ticket = try approvalRequests.submit(
                reservation.write.approvalRequest,
                trustedCredentialDeadline: reservation.write.credentialExpiresAt.map {
                    .expiresAt($0)
                } ?? .none
            )
            return .submitted(submission(operationID: request.operationID, ticket: ticket))
        } catch {
            if reservation.inserted {
                agentTextWrites.remove(operationID: request.operationID)
            }
            throw error
        }
    }

    private func submission(
        operationID: String,
        ticket: BrokerApprovalTicket
    ) -> AgentTextWriteSubmission {
        AgentTextWriteSubmission(
            operationID: operationID,
            requestID: ticket.requestID,
            capability: ticket.capability,
            state: ticket.state,
            retryCount: ticket.retryCount
        )
    }

    public func cancelAgentTextWrite(
        operationID: String,
        requestID: String,
        capability: String
    ) throws -> BrokerRequestState {
        if agentOrganizations.entry(operationID: operationID) != nil {
            return try cancelAgentOrganization(operationID: operationID, requestID: requestID, capability: capability)
        }
        return try agentTextWrites.synchronized {
            guard let frozen = agentTextWrites.entry(operationID: operationID) else {
                throw BrokerApprovalError.requestNotFound
            }
            let state = try approvalRequests.cancel(
                requestID: requestID,
                capability: capability,
                operationRequest: frozen.approvalRequest
            )
            if state == .cancelled || state == .denied || state == .expired {
                agentTextWrites.remove(operationID: operationID)
            }
            return state
        }
    }

    private func validateAgentTextWrite(_ request: AgentTextWriteRequest) throws {
        guard request.isBounded else { throw BrokerApprovalError.invalidRequest }
    }

    func agentTextWriteDigest(_ request: AgentTextWriteRequest) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(request)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
