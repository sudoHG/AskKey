import Foundation

extension BrokerApprovalStateMachine {
    /// App-supplied live session check. The provider must be pure, nonblocking,
    /// and must not call back into the Broker or Vault while the lock is held.
    package func configureTimedAllowanceScreenState(_ unlocked: @escaping @Sendable () -> Bool) {
        mutate { timedAllowanceScreenUnlocked = unlocked }
    }

    func timedAllowanceSessionPermitsGrantLocked() -> Bool {
        !timedAllowanceSessionSuspended && (timedAllowanceScreenUnlocked?() ?? timedAllowanceSessionActive)
    }

    /// Backstop delayed/missed distributed events before cached authority is
    /// used. A fresh unlocked sample can supersede a stale cached screen flag,
    /// but cannot undo an explicit sleep or inactive console session.
    func revokeForScreenBackstopLocked() -> ([String], @Sendable (String) -> Void)? {
        guard endTimedAllowancesOnLock, let unlocked = timedAllowanceScreenUnlocked,
              timedAllowanceSessionSuspended || !unlocked() else { return nil }
        timedAllowanceSessionGeneration = UUID()
        return revokeAllTimedAllowancesLocked()
    }
}
