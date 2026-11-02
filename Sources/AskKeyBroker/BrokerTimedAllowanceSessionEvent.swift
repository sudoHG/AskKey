import Foundation

/// A receipt-time fence remains closed until its queued session update finishes.
package final class BrokerTimedAllowanceSessionEvent: @unchecked Sendable {
    package let sleepOffsetUpperBound: UInt64?
    private let lock = NSLock()
    private var completed = false
    private let complete: @Sendable () -> Void

    init(sleepOffsetUpperBound: UInt64?, complete: @escaping @Sendable () -> Void) {
        self.sleepOffsetUpperBound = sleepOffsetUpperBound
        self.complete = complete
    }

    package func finish() {
        lock.lock()
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { complete() }
    }
}

/// Independent of the approval lock: recording an event never waits for a
/// WindowServer query, Vault policy read, runtime cleanup or approval mutation.
final class TimedAllowanceSessionFence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var revision = UUID()
    private var sleepOffset: @Sendable () -> (lower: UInt64, upper: UInt64) = {
        BrokerApprovalStateMachine.currentTimedAllowanceSleepOffset()
    }

    var snapshot: (pending: Bool, revision: UUID) {
        lock.lock()
        defer { lock.unlock() }
        return (count > 0, revision)
    }

    func configureSleepOffset(_ offset: @escaping @Sendable () -> (lower: UInt64, upper: UInt64)) {
        lock.lock()
        sleepOffset = offset
        lock.unlock()
    }

    func begin(sleeping: Bool?) -> BrokerTimedAllowanceSessionEvent {
        lock.lock()
        count += 1
        revision = UUID()
        let offset = sleepOffset
        lock.unlock()
        return BrokerTimedAllowanceSessionEvent(sleepOffsetUpperBound: sleeping == true ? offset().upper : nil) {
            self.lock.lock()
            self.count -= 1
            self.revision = UUID()
            self.lock.unlock()
        }
    }
}
