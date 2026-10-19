import Foundation

/// The App supplies a socket-identity check; no filesystem IO runs under this lock.
final class AgentAccessPolicyOwnership {
    private enum State { case unavailable, owned(() -> Bool, (Error) -> Void), revoked }
    private let lock = NSLock()
    private var state = State.unavailable
    private var generation = 0

    var isRevoked: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .revoked = state { return true }
        return false
    }

    func set(_ owned: Bool, validate: @escaping () -> Bool = { true }, onRevocation: @escaping (Error) -> Void = { _ in }) {
        lock.lock(); defer { lock.unlock() }
        state = owned ? .owned(validate, onRevocation) : .unavailable
        generation += 1
    }

    func require() throws {
        while true {
            lock.lock()
            let snapshot = state
            let version = generation
            lock.unlock()
            switch snapshot {
            case .unavailable: throw AgentAccessPolicyError.notOwner
            case .revoked: throw AgentAccessPolicyError.ownershipRevoked
            case .owned(let validate, let onRevocation):
                let valid = validate()
                lock.lock()
                guard version == generation else { lock.unlock(); continue }
                if !valid { state = .revoked; generation += 1 }
                lock.unlock()
                guard valid else {
                    onRevocation(AgentAccessPolicyError.ownershipRevoked)
                    throw AgentAccessPolicyError.ownershipRevoked
                }
                return
            }
        }
    }
}
