import Foundation
import AskKeyBroker

final class FrozenAgentOrganizationRegistry: @unchecked Sendable {
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var entries: [String: FrozenAgentOrganization] = [:]

    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock(); defer { operationLock.unlock() }
        return try body()
    }

    func store(_ candidate: FrozenAgentOrganization) throws {
        try withEntries {
            if let existing = entries[candidate.request.operationID] {
                guard existing.digest == candidate.digest else { throw BrokerApprovalError.payloadMismatch }
                return
            }
            guard entries.count < BrokerLimits.maximumPendingApprovalRequests else {
                throw BrokerApprovalError.capacityReached
            }
            entries[candidate.request.operationID] = candidate
        }
    }

    func entry(operationID: String) -> FrozenAgentOrganization? {
        withEntries { entries[operationID] }
    }

    func remove(operationID: String) {
        _ = withEntries { entries.removeValue(forKey: operationID) }
    }

    private func withEntries<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
