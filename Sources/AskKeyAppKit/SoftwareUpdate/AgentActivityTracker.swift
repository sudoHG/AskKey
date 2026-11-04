import Foundation
import AskKeyBroker

/// Records the Agent work a relaunch would interrupt (ADR 0011). Broker
/// threads report their calls here; the relaunch gate reads the counts.
/// It holds request and upload identifiers only, never credential material.
// Safe: every access to mutable state is lock-guarded.
final class AgentActivityTracker: @unchecked Sendable {
    /// `BrokerFileWriteCoordinator`'s default upload lifetime, which the App
    /// uses. Every upload call renews it, so an upload nobody touched for this
    /// long has expired in the Broker as well.
    static let uploadLifetime: TimeInterval = 5 * 60

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var runningCalls = 0
    private var uploadExpiries: [String: Date] = [:]
    /// Capability for each approval seen pending, kept until it is neither
    /// pending nor approved.
    private var approvalCapabilities: [String: String] = [:]

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    /// Starts counting a running Agent call; pair every call with `endCall()`.
    func beginCall() {
        lock.withLock { runningCalls += 1 }
    }

    func endCall() {
        lock.withLock { runningCalls = max(0, runningCalls - 1) }
    }

    /// A running call that also keeps track of the uploads it opens and closes.
    func fileWrite(
        _ request: BrokerFileWriteRequest,
        _ body: () throws -> BrokerFileWritePayload
    ) rethrows -> BrokerFileWritePayload {
        beginCall(); defer { endCall() }
        let payload = try body()
        record(request, payload: payload)
        return payload
    }

    var runningCallCount: Int {
        lock.withLock { runningCalls }
    }

    var openUploadCount: Int {
        lock.withLock {
            let now = clock()
            uploadExpiries = uploadExpiries.filter { $0.value > now }
            return uploadExpiries.count
        }
    }

    /// Remembers the approvals now waiting, so they can still be seen once
    /// approved and no longer pending, then counts the remembered approvals
    /// that are still pending or approved and forgets every other one.
    /// `status` returns nil for a request the Broker no longer knows.
    @discardableResult
    func refreshApprovals(
        pending approvals: [BrokerPendingApproval],
        status: (_ requestID: String, _ capability: String) -> BrokerRequestState?
    ) -> (pending: Int, approved: Int) {
        let remembered = lock.withLock {
            for approval in approvals {
                approvalCapabilities[approval.requestID] = approval.capability
            }
            return approvalCapabilities
        }
        var pending = 0
        var approved = 0
        var finished: [String] = []
        for (requestID, capability) in remembered {
            switch status(requestID, capability) {
            case .pending: pending += 1
            case .approved: approved += 1
            default: finished.append(requestID)
            }
        }
        lock.withLock {
            for requestID in finished { approvalCapabilities.removeValue(forKey: requestID) }
        }
        return (pending, approved)
    }

    private func record(_ request: BrokerFileWriteRequest, payload: BrokerFileWritePayload) {
        lock.withLock {
            let renewed = clock().addingTimeInterval(Self.uploadLifetime)
            switch request {
            case .begin, .beginComponent:
                if case .upload(let ticket) = payload { uploadExpiries[ticket.uploadID] = renewed }
            case .append(let chunk):
                if uploadExpiries[chunk.uploadID] != nil { uploadExpiries[chunk.uploadID] = renewed }
            case .freezeComponent(let freeze):
                // A frozen component stays staged until a write request uses it.
                if uploadExpiries[freeze.uploadID] != nil { uploadExpiries[freeze.uploadID] = renewed }
            case .freeze(let freeze), .cancelUpload(let freeze):
                // A frozen file now waits as a pending approval.
                uploadExpiries.removeValue(forKey: freeze.uploadID)
            }
        }
    }
}
