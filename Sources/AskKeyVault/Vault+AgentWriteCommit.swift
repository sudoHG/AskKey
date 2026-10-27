import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func commitAgentTextWrite(
        _ request: AgentTextWriteRequest,
        requestID: String,
        capability: String
    ) throws -> AgentTextWriteResult {
        if case .organize = request.action {
            return try commitAgentOrganization(request, requestID: requestID, capability: capability)
        }
        let operation: CredentialAccessEvent.Operation
        switch request.action {
        case .create, .createBundle: operation = .create
        case .modify, .modifyBundle: operation = .modify
        case .organize: operation = .modify
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
        var wasPaused = try agentAccessGate.beginExclusiveAgentChange()
        var changed = false
        defer { finishCredentialChange(wasPaused: wasPaused, snapshotChanged: changed) }
        try revalidateExclusiveAgentAccess(paused: &wasPaused)
        let result = try agentTextWrites.synchronized {
            try commitAgentTextWriteSynchronized(
                request,
                requestID: requestID,
                capability: capability,
                snapshotChanged: &changed
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
        capability: String,
        snapshotChanged: inout Bool
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
            cancelAgentWritesForExpiry(credentialID: frozen.approvalRequest.credentialID)
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
                    credentialGroupsKey: try requireKey(),
                    rebuildComponents: frozen.componentChanges.isEmpty ? nil : { current in
                        try self.rebuildAgentWriteComponents(frozen, current: current, key: self.requireKey())
                    }
                )
            }
            agentTextWrites.remove(operationID: request.operationID)
            brokerRequests.cancelPending(credentialID: result.credentialID)
            approvalRequests.cancelPending(credentialID: result.credentialID)
            snapshotChanged = true
            return result
        } catch VaultError.credentialUnavailable {
            cancelAgentWritesForExpiry(credentialID: frozen.approvalRequest.credentialID)
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

    private func rebuildAgentWriteComponents(_ frozen: FrozenAgentTextWrite, current: CredentialRecord,
        key: SymmetricKey) throws -> CredentialRecord {
        // This closure runs inside the approved transaction, after row-state,
        // authentication and expiry checks. Open the old payload exactly once.
        let before = try credentialComponents(from: current, key: key)
        guard try CredentialComponentMetadata.read(from: current, using: key) == CredentialComponentMetadata(components: before) else {
            throw CredentialRecordAuthenticationError.invalidAuthentication
        }
        let merged = try FrozenAgentComponentChange.applying(frozen.componentChanges, to: before,
            name: { $0.name }, replacement: { $0 })
        let size = merged.reduce(0) { total, component in
            switch component.value {
            case .text(let value): return total + value.utf8.count
            case .file(_, let bytes): return total + bytes.count
            }
        }
        guard size <= CredentialBundleValidator.maximumMaterialBytes else { throw VaultError.agentWriteMaterialTooLarge }
        let components = try CredentialBundleValidator.validatedComponents(merged)
        guard case .modify(var record, _) = frozen.mutation else { throw BrokerApprovalError.invalidRequest }
        record.payloadKind = CredentialPayloadKind.bundle.rawValue
        record.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key)
        record.encryptedComponentMetadata = try CredentialComponentMetadata(components: components).encrypted(using: key)
        record.encryptedEnvironmentVariable = nil
        record.encryptedOriginalFilename = nil
        record.byteSize = nil
        record.contentDigest = nil
        return record
    }

    private func cancelAgentWritesForExpiry(credentialID: String) {
        brokerRequests.cancelPending(credentialID: credentialID)
        approvalRequests.cancelPendingForExpiry(credentialID: credentialID)
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
