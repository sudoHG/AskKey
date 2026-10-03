import Foundation

/// Capability-bound request state owned by the App. Later request-producing
/// stages register operations here; public callers can only query or cancel an
/// entry when both its id and unguessable capability match.
// Safe: every access to mutable state is lock-guarded.
public final class BrokerRequestRegistry: @unchecked Sendable {
    private struct PendingState {
        let capability: String
        let credentialID: String?
    }

    private struct RetainedState {
        let capability: String
        var state: BrokerRequestState
    }

    private let lock = NSLock()
    private var pendingStates: [String: PendingState] = [:]
    private var retainedStates: [String: RetainedState] = [:]
    private var retainedOrder: [String] = []
    private var paused = false

    public init() {}

    public func register(requestID: String, capability: String, credentialID: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { throw BrokerRequestRegistryError.agentAccessPaused }
        guard pendingStates[requestID] == nil, retainedStates[requestID] == nil else {
            throw BrokerRequestRegistryError.duplicateRequest
        }
        guard pendingStates.count < BrokerLimits.maximumPendingApprovalRequests else {
            throw BrokerRequestRegistryError.capacityReached
        }
        pendingStates[requestID] = PendingState(capability: capability, credentialID: credentialID)
    }

    public func status(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        if pendingStates[requestID]?.capability == capability { return .pending }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return nil }
        return retained.state
    }

    public func cancel(requestID: String, capability: String) -> BrokerRequestState? {
        lock.lock(); defer { lock.unlock() }
        if pendingStates[requestID]?.capability == capability {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: capability, state: .cancelled)
            return .cancelled
        }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return nil }
        return retained.state
    }

    @discardableResult
    public func cancelAllPending() -> Int {
        lock.lock(); defer { lock.unlock() }
        return cancelAllPendingLocked()
    }

    @discardableResult
    public func cancelPending(credentialID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let matching = pendingStates.filter { $0.value.credentialID == credentialID }
        for (requestID, pending) in matching {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: pending.capability, state: .cancelled)
        }
        return matching.count
    }

    public func pauseAndCancelAll() {
        lock.lock(); defer { lock.unlock() }
        paused = true
        _ = cancelAllPendingLocked()
    }

    public func resume() {
        lock.lock(); defer { lock.unlock() }
        paused = false
    }

    private func cancelAllPendingLocked() -> Int {
        let pending = pendingStates
        pendingStates.removeAll()
        for (requestID, state) in pending {
            retain(requestID: requestID, capability: state.capability, state: .cancelled)
        }
        return pending.count
    }

    @discardableResult
    public func setState(requestID: String, capability: String, state: BrokerRequestState) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == .pending { return pendingStates[requestID]?.capability == capability }
        if pendingStates[requestID]?.capability == capability {
            pendingStates.removeValue(forKey: requestID)
            retain(requestID: requestID, capability: capability, state: state)
            return true
        }
        guard let retained = retainedStates[requestID], retained.capability == capability else { return false }
        return retained.state == state
    }

    private func retain(requestID: String, capability: String, state: BrokerRequestState) {
        retainedStates[requestID] = RetainedState(capability: capability, state: state)
        retainedOrder.append(requestID)
        if retainedOrder.count > BrokerLimits.maximumRetainedRequestStates {
            retainedStates.removeValue(forKey: retainedOrder.removeFirst())
        }
    }
}
