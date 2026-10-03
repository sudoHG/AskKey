import Foundation
import AskKeyBroker

final class FrozenAgentTextWriteRegistry: @unchecked Sendable {
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var entries: [String: FrozenAgentTextWrite] = [:]

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock(); defer { operationLock.unlock() }
        return try body()
    }

    func store(_ candidate: FrozenAgentTextWrite) throws -> (write: FrozenAgentTextWrite, inserted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[candidate.operationID] {
            guard existing.digest == candidate.digest else {
                throw BrokerApprovalError.payloadMismatch
            }
            return (existing, false)
        }
        guard entries.count < BrokerLimits.maximumPendingApprovalRequests else {
            throw BrokerApprovalError.capacityReached
        }
        entries[candidate.operationID] = candidate
        return (candidate, true)
    }

    func entry(operationID: String) -> FrozenAgentTextWrite? {
        lock.lock(); defer { lock.unlock() }
        return entries[operationID]
    }

    func remove(operationID: String) {
        operationLock.lock(); defer { operationLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: operationID)
    }
}
