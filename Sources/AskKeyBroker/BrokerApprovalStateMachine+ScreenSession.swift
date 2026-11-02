import Foundation
import Darwin

extension BrokerApprovalStateMachine {
    /// App-supplied live session check. The provider must be pure, nonblocking,
    /// and must not call back into the Broker or Vault while the lock is held.
    package func configureTimedAllowanceScreenState(_ unlocked: @escaping @Sendable () -> Bool) {
        mutate { timedAllowanceScreenUnlocked = unlocked }
    }

    package func configureTimedAllowanceSleepOffset(
        _ offset: @escaping @Sendable () -> (lower: UInt64, upper: UInt64)
    ) {
        mutate { timedAllowanceSleepOffset = offset }
    }

    static func currentTimedAllowanceSleepOffset() -> (lower: UInt64, upper: UInt64) {
        // Bracket the continuous clock to bound sampling jitter. Only sleep
        // advances continuous time without advancing absolute time.
        let before = mach_absolute_time()
        let continuous = mach_continuous_time()
        let after = mach_absolute_time()
        return (continuous > after ? continuous - after : 0,
                continuous > before ? continuous - before : 0)
    }

    func timedAllowanceSessionPermitsGrantLocked() -> Bool {
        if let unlocked = timedAllowanceScreenUnlocked?() {
            // An unlocked sample before actual sleep cannot clear willSleep.
            // Strictly separated bounds prove sleep occurred despite a missed wake.
            if unlocked, timedAllowanceSessionSleeping, let offset = timedAllowanceSleepOffsetAtSleep,
               timedAllowanceSleepOffset().lower > offset {
                timedAllowanceSessionSleeping = false
                timedAllowanceSleepOffsetAtSleep = nil
            }
            return unlocked && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
        }
        return timedAllowanceSessionActive && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
    }

    /// Backstop delayed/missed distributed events before cached authority is
    /// used. A fresh unlocked sample can supersede a stale cached screen flag,
    /// and clear a missed wake after proven sleep, but cannot undo an inactive
    /// console session.
    func revokeForScreenBackstopLocked() -> ([String], @Sendable (String) -> Void)? {
        guard endTimedAllowancesOnLock, timedAllowanceScreenUnlocked != nil,
              !timedAllowanceSessionPermitsGrantLocked() else { return nil }
        timedAllowanceSessionGeneration = UUID()
        return revokeAllTimedAllowancesLocked()
    }
}
