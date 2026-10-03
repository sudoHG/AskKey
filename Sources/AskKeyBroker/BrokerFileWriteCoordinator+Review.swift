import CryptoKit
import Darwin
import Foundation

extension BrokerFileWriteCoordinator {
    public func summary(requestID: String) throws -> BrokerFileWriteSummary {
        try withLock {
            purgeExpiredLocked(now: clock())
            guard let session = session(requestID: requestID),
                  let approval = session.approval,
                  let digest = session.contentDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            let state = try approvals.status(
                requestID: approval.requestID,
                capability: approval.capability
            )
            return .init(
                targetID: session.targetID,
                operation: session.operation,
                payloadKind: .file,
                originalFilename: session.originalFilename,
                byteCount: session.receivedByteCount,
                previousDigest: session.previousDigest,
                digest: digest,
                payloadMasked: true,
                state: state
            )
        }
    }

    public func reveal(requestID: String) throws -> BrokerFrozenFile {
        guard withLock({
            purgeExpiredLocked(now: clock())
            return session(requestID: requestID) != nil
        }) else {
            throw BrokerFileWriteError.requestNotFound
        }
        guard authenticateReveal() else { throw BrokerFileWriteError.authenticationFailed }
        return try withLock {
            purgeExpiredLocked(now: clock())
            guard let session = session(requestID: requestID) else {
                throw BrokerFileWriteError.requestNotFound
            }
            guard let approval = session.approval, let digest = session.approvalDigest else {
                throw BrokerFileWriteError.requestNotFound
            }
            let state = try approvals.status(
                requestID: approval.requestID,
                capability: approval.capability,
                operationRequest: approvalRequest(session: session, digest: digest)
            )
            guard state == .pending || state == .approved else {
                throw BrokerFileWriteError.requestNotFound
            }
            return try frozenFile(session)
        }
    }

    @discardableResult
    public func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        try approvals.decide(
            requestID: requestID,
            capability: capability,
            decision: decision
        )
    }
}
