import Foundation
import AskKeyBroker

final class AgentAccessGate: @unchecked Sendable {
    private enum State { case active, paused, invalid }

    private let condition = NSCondition()
    private var state: State = .paused
    private var activeOperations = 0
    private var changing = false

    func beginAgentOperation(validating policy: () throws -> Void = {}) throws {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .active:
            try policy()
            activeOperations += 1
        case .paused: throw VaultError.agentAccessPaused
        case .invalid: throw invalidStateError
        }
    }

    func endAgentOperation() {
        condition.lock()
        if activeOperations > 0 { activeOperations -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    /// Keeps the gate condition locked across the final expiry check and spawn.
    /// An exclusive mutation either marks the gate paused first or waits until
    /// the target exists; there is no check-then-spawn gap.
    func beginSpawnAuthorization(validating policy: () throws -> Void = {}) throws {
        condition.lock()
        guard state == .active else {
            condition.unlock()
            throw BrokerProviderError.requestRejected
        }
        do { try policy() }
        catch { condition.unlock(); throw error }
    }

    /// Only while the authorization caller holds the condition. This transition
    /// must not wait for active leases, including the lease doing this check.
    func setPausedDuringAuthorization(_ paused: Bool) {
        state = paused ? .paused : .active
    }

    func endSpawnAuthorization() {
        condition.unlock()
    }

    /// Agent writes share the spawn exclusion boundary without gaining the
    /// ability to operate while access was already paused.
    func beginExclusiveAgentChange() throws -> Bool {
        condition.lock()
        while changing { condition.wait() }
        guard state == .active else {
            let error: Error = state == .paused ? VaultError.agentAccessPaused : invalidStateError
            condition.unlock()
            throw error
        }
        changing = true
        state = .paused
        while activeOperations > 0 { condition.wait() }
        condition.unlock()
        return false
    }

    func beginExclusiveChange() throws -> Bool {
        condition.lock()
        while changing { condition.wait() }
        guard state != .invalid else {
            condition.unlock()
            throw invalidStateError
        }
        changing = true
        let wasPaused = state == .paused
        state = .paused
        while activeOperations > 0 { condition.wait() }
        condition.unlock()
        return wasPaused
    }

    func endExclusiveChange(paused: Bool) {
        condition.lock()
        state = paused ? .paused : .active
        changing = false
        condition.broadcast()
        condition.unlock()
    }

    func invalidate() {
        condition.lock()
        state = .invalid
        condition.broadcast()
        condition.unlock()
    }

    func isPaused() throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .active: return false
        case .paused: return true
        case .invalid: throw invalidStateError
        }
    }

    private var invalidStateError: VaultError {
        .databaseError("Agent access pause state is invalid.")
    }
}
