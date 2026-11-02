import Foundation

extension BrokerApprovalStateMachine {
    /// App-supplied live session check. The provider must be pure, nonblocking,
    /// and must not call back into the Broker or Vault while the lock is held.
    package func configureTimedAllowanceScreenState(_ unlocked: @escaping @Sendable () -> Bool) {
        mutate { timedAllowanceScreenUnlocked = unlocked }
    }

    func timedAllowanceSessionPermitsGrantLocked() -> Bool {
        if let unlocked = timedAllowanceScreenUnlocked?() {
            // A running process on its unlocked console is awake, even if
            // didWake was missed. This cannot restore revoked authority.
            if unlocked { timedAllowanceSessionSleeping = false }
            return unlocked && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
        }
        return timedAllowanceSessionActive && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
    }

    /// Backstop delayed/missed distributed events before cached authority is
    /// used. A fresh unlocked sample can supersede a stale cached screen flag,
    /// and clear a missed wake, but cannot undo an inactive console session.
    func revokeForScreenBackstopLocked() -> ([String], @Sendable (String) -> Void)? {
        guard endTimedAllowancesOnLock, timedAllowanceScreenUnlocked != nil,
              !timedAllowanceSessionPermitsGrantLocked() else { return nil }
        timedAllowanceSessionGeneration = UUID()
        return revokeAllTimedAllowancesLocked()
    }
}
