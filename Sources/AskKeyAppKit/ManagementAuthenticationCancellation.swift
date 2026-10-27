import Foundation
import AskKeyVault
import AskKeyBroker

/// One handle per attempt, including attempts still waiting for the prompt queue.
final class ManagementAuthenticationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    private let requestEnded: @Sendable () -> Bool

    init(requestEnded: @escaping @Sendable () -> Bool = { false }) {
        self.requestEnded = requestEnded
    }

    var isCancelled: Bool {
        if requestEnded() { cancel() }
        return lock.withLock { cancelled }
    }

    func cancel() {
        let callbacks = lock.withLock {
            cancelled = true
            let callbacks = Array(handlers.values)
            handlers.removeAll()
            return callbacks
        }
        callbacks.forEach { $0() }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock {
            if cancelled { return true }
            handlers[id] = handler
            return false
        }
        if alreadyCancelled { handler() }
        return id
    }

    func removeObserver(_ id: UUID) {
        _ = lock.withLock { handlers.removeValue(forKey: id) }
    }
}

package enum ManagementAuthenticationResult {
    case authenticated(ManagementAuthenticator)
    case cancelled
    case failed

    init(_ outcome: ManagementAuthenticationOutcome) {
        switch outcome {
        case .authenticated: self = .authenticated(.allow)
        case .cancelled: self = .cancelled
        case .failed: self = .failed
        }
    }

    var messageKey: String? {
        switch self {
        case .authenticated: nil
        case .cancelled: "Authentication cancelled."
        case .failed: "System authentication failed."
        }
    }
}

/// The broker keeps its Bool gate; this request-local context preserves the
/// detailed result for the UI without changing what that gate protects.
package final class ApprovalAuthenticationAttempt: @unchecked Sendable {
    @TaskLocal package static var current: ApprovalAuthenticationAttempt?
    let cancellation: ManagementAuthenticationCancellation
    private let lock = NSLock()
    private var result: ManagementAuthenticationOutcome = .failed

    init(requestEnded: @escaping @Sendable () -> Bool) {
        cancellation = ManagementAuthenticationCancellation(requestEnded: requestEnded)
    }

    convenience init(
        pending: BrokerPendingApproval,
        requests: BrokerApprovalStateMachine,
        screenUnlocked: @escaping @Sendable () -> Bool
    ) {
        self.init {
            !screenUnlocked() || (try? requests.status(
                requestID: pending.requestID, capability: pending.capability
            )) != .pending
        }
    }

    var outcome: ManagementAuthenticationOutcome { lock.withLock { result } }

    package func record(_ outcome: ManagementAuthenticationOutcome) -> Bool {
        lock.withLock { result = outcome }
        return outcome == .authenticated && !cancellation.isCancelled
    }
}
