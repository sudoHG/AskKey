import Foundation
import Darwin

extension BrokerApprovalStateMachine {
    /// App-supplied live session check, called outside the approval lock.
    /// Providers must not recursively start another screen-sampling mutation.
    package func configureTimedAllowanceScreenState(_ unlocked: @escaping @Sendable () -> Bool) {
        mutate(screenProvider: unlocked) {
            timedAllowanceScreenUnlocked = unlocked
            timedAllowanceSessionRevision = UUID()
        }
    }

    package func configureTimedAllowanceSleepOffset(
        _ offset: @escaping @Sendable () -> (lower: UInt64, upper: UInt64)
    ) {
        mutate {
            timedAllowanceSessionRevision = UUID()
            timedAllowanceSleepOffset = offset
            timedAllowanceSessionFence.configureSleepOffset(offset)
        }
    }

    /// The observer calls this at receipt of each ending event, never for resume.
    /// Only that event's completion can release its fence.
    package func beginTimedAllowanceSessionEvent(sleeping: Bool?) -> BrokerTimedAllowanceSessionEvent {
        timedAllowanceSessionFence.begin(sleeping: sleeping)
    }

    /// Returns with the approval lock held. An unlocked sample is usable only
    /// for this mutation and only if no state or event changed during sampling.
    /// One retry bounds contention; a second race refuses timed authority.
    func lockWithTimedAllowanceScreenSample(
        screenProvider: (@Sendable () -> Bool)?, endOnLock: Bool?
    ) {
        for attempt in 0...1 {
            lock.lock()
            let enabled = endOnLock ?? endTimedAllowancesOnLock
            let provider = enabled ? (screenProvider ?? timedAllowanceScreenUnlocked) : nil
            guard let provider else {
                timedAllowanceScreenSample = nil
                timedAllowanceScreenSampleFailed = false
                return
            }
            let revision = timedAllowanceSessionRevision
            let fenceRevision = timedAllowanceSessionFence.snapshot.revision
            lock.unlock()
            let sample = provider()
            lock.lock()
            if timedAllowanceSessionRevision == revision, timedAllowanceSessionFence.snapshot.revision == fenceRevision {
                timedAllowanceScreenSample = sample
                timedAllowanceScreenSampleFailed = false
                return
            }
            if attempt == 1 {
                timedAllowanceScreenSample = nil
                timedAllowanceScreenSampleFailed = true
                return
            }
            lock.unlock()
        }
    }

    func clearTimedAllowanceScreenSampleLocked() {
        timedAllowanceScreenSample = nil
        timedAllowanceScreenSampleFailed = false
    }

    static func currentTimedAllowanceSleepOffset() -> (lower: UInt64, upper: UInt64) {
        // Bracket the continuous clock to bound sampling jitter. Only sleep
        // advances continuous time without advancing absolute time.
        // The bounds rely on in-order counter reads: absolute, continuous, absolute.
        let before = mach_absolute_time()
        let continuous = mach_continuous_time()
        let after = mach_absolute_time()
        return (continuous > after ? continuous - after : 0,
                continuous > before ? continuous - before : 0)
    }

    func timedAllowanceSessionPermitsGrantLocked() -> Bool {
        guard !timedAllowanceSessionFence.snapshot.pending, !timedAllowanceScreenSampleFailed else { return false }
        if let unlocked = timedAllowanceScreenSample {
            // Proven sleep may be cleared here even on the runtime gate path;
            // this changes no authority records and publishes no callbacks.
            clearTimedAllowanceSleepIfProvenLocked(unlocked: unlocked)
            return unlocked && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
        }
        return timedAllowanceSessionActive && !timedAllowanceSessionSuspended && !timedAllowanceSessionSleeping
    }

    func clearTimedAllowanceSleepIfProvenLocked(unlocked: Bool) {
        // An unlocked sample before actual sleep cannot clear willSleep.
        // Strictly separated bounds prove sleep occurred despite a missed wake.
        guard unlocked, timedAllowanceSessionSleeping, let offset = timedAllowanceSleepOffsetAtSleep,
              timedAllowanceSleepOffset().lower > offset else { return }
        timedAllowanceSessionSleeping = false
        timedAllowanceSleepOffsetAtSleep = nil
    }

    /// Backstop delayed/missed distributed events before cached authority is
    /// used. A fresh unlocked sample can supersede a stale cached screen flag,
    /// and clear a missed wake after proven sleep, but cannot undo an inactive
    /// console session.
    func revokeForScreenBackstopLocked() -> ([String], @Sendable (String) -> Void)? {
        guard endTimedAllowancesOnLock,
              !timedAllowanceScreenSampleFailed || timedAllowanceSessionFence.snapshot.pending,
              timedAllowanceScreenSample != nil || timedAllowanceScreenUnlocked != nil
                || timedAllowanceSessionFence.snapshot.pending,
              !timedAllowanceSessionPermitsGrantLocked() else { return nil }
        timedAllowanceSessionGeneration = UUID()
        return revokeAllTimedAllowancesLocked()
    }
}
