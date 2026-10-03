@testable import AskKeyBroker
import Foundation
import Darwin

final class PendingRunTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var approved = false
    private var resolverCalls = 0
    private var starts = 0

    var isApproved: Bool {
        lock.lock(); defer { lock.unlock() }
        return approved
    }

    var resolverCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resolverCalls
    }

    var spawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    func recordResolverCall() {
        lock.lock(); defer { lock.unlock() }
        resolverCalls += 1
    }

    func recordSpawn() {
        lock.lock(); defer { lock.unlock() }
        starts += 1
    }

    func approve() {
        lock.lock(); defer { lock.unlock() }
        approved = true
    }
}
