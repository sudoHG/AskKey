import Foundation

extension BrokerApprovalStateMachine {
    /// Test seam: the state machine owns at most one reschedulable expiration task.
    var scheduledExpirationTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return hasScheduledExpiration ? 1 : 0
    }

    func expireUnconsumedLocked(now: Date) {
        for operationID in entriesByOperationID.keys {
            guard var entry = entriesByOperationID[operationID],
                  entry.state == .pending || entry.state == .approved,
                  !entry.committing,
                  now >= entry.expiresAt else { continue }
            entry.state = .expired
            entriesByOperationID[operationID] = entry
        }
    }

    func expireTimedAllowancesLocked(now: Date) {
        timedAllowances = timedAllowances.filter { $0.value > now }
    }

    func expireScheduledRequests() {
        let now = clock()
        mutate {
            expireUnconsumedLocked(now: now)
            expireTimedAllowancesLocked(now: now)
        }
    }

    static func validDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0
    }

    func rescheduleExpirationLocked(now: Date) {
        let requestExpirations = entriesByOperationID.values
            .filter { !$0.committing && ($0.state == .pending || $0.state == .approved) }
            .map(\.expiresAt)
        let runtimeExpirations = runtimeAuthorizations.values.filter(\.valid).map(\.expiresAt)
        let nextExpiration = (requestExpirations + runtimeExpirations + Array(timedAllowances.values)).min()
        guard let nextExpiration else {
            hasScheduledExpiration = false
            expirationTimer.schedule(deadline: .distantFuture)
            return
        }
        hasScheduledExpiration = true
        let delay = max(0, nextExpiration.timeIntervalSince(now))
        expirationTimer.schedule(
            deadline: .now() + delay,
            repeating: .never,
            leeway: .milliseconds(10)
        )
    }
}
