import CryptoKit
import Darwin
import Foundation

extension BrokerFileWriteCoordinator {
    public func commit(
        requestID: String,
        capability: String,
        expectedDigest: String
    ) throws {
        try commit(
            requestID: requestID,
            capability: capability,
            expectedDigest: expectedDigest,
            consume: commitFrozenFile
        )
    }

    func commit(
        requestID: String,
        capability: String,
        expectedDigest: String,
        consume: (BrokerFrozenFile) throws -> Void
    ) throws {
        try withLock {
            // A database receipt survives both staging cleanup and a process
            // restart, including the DB-commit -> approval-consumed crash window.
            if try completedFileCommit(requestID, capability, expectedDigest) {
                if let existing = session(requestID: requestID), let digest = existing.approvalDigest,
                   (try? approvals.status(requestID: requestID, capability: capability)) == .approved {
                    _ = try? approvals.consume(requestID: requestID, capability: capability,
                        operationRequest: approvalRequest(session: existing, digest: digest))
                }
                retainCompletedUploads(requestID: requestID)
                return
            }
            purgeExpiredLocked(now: clock())
            guard let match = sessions.first(where: { $0.value.approval?.requestID == requestID }),
                  let approval = match.value.approval,
                  approval.capability == capability,
                  let contentDigest = match.value.contentDigest,
                  let approvalDigest = match.value.approvalDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            guard Self.constantTimeEqual(contentDigest, expectedDigest) else {
                throw BrokerFileWriteError.digestMismatch
            }
            let currentPreviousDigest = match.value.operation == .modify
                ? try resolvePreviousDigest(match.value.credentialID)
                : nil
            guard currentPreviousDigest.map(Self.validDigest) ?? true else {
                throw BrokerFileWriteError.invalidRequest
            }
            guard Self.equalDigest(currentPreviousDigest, match.value.previousDigest) else {
                throw BrokerFileWriteError.targetChanged
            }
            let file = try frozenFile(match.value)
            do {
                // ponytail: file writes are rare and capped; one lock keeps commit,
                // approval consumption, and replay exclusion linearizable.
                _ = try approvals.consume(
                    requestID: requestID,
                    capability: capability,
                    operationRequest: BrokerApprovalOperationRequest(
                        operationID: match.value.operationID,
                        credentialID: match.value.credentialID,
                        targetID: match.value.targetID,
                        operation: match.value.operation,
                        payloadDigest: approvalDigest
                    ),
                    performing: { try consume(file) }
                )
            } catch let error as BrokerApprovalError {
                throw error
            } catch {
                throw BrokerFileWriteError.outcomeUnknown
            }
            retainCompletedUploads(requestID: requestID)
        }
    }

    private func retainCompletedUploads(requestID: String) {
        let completed = sessions.filter { $0.value.approval?.requestID == requestID }
        for (uploadID, session) in completed {
            guard let approval = session.approval else { continue }
            completedUploads[uploadID] = .init(capability: session.capability,
                ticket: .init(requestID: approval.requestID, capability: approval.capability,
                    state: .consumed, retryCount: approval.retryCount))
            completedUploadOrder.append(uploadID)
            sessions.removeValue(forKey: uploadID)
            try? FileManager.default.removeItem(at: session.stagingURL)
        }
        while completedUploadOrder.count > BrokerLimits.maximumRetainedRequestStates {
            completedUploads.removeValue(forKey: completedUploadOrder.removeFirst())
        }
    }
}
