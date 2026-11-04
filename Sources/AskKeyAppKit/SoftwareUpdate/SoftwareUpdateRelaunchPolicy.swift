import Foundation

/// The work a relaunch would interrupt, sampled when Sparkle is ready to
/// relaunch (ADR 0011). Timed allowances are deliberately absent: they can
/// last hours, so Settings states that a relaunch ends them instead.
package struct SoftwareUpdateActivity: Equatable, Sendable {
    /// Approval prompts waiting for the user's decision.
    package var pendingApprovals: Int
    /// Approved requests the agent has not used yet. A relaunch would lose
    /// the approval and make the agent ask again.
    package var unusedApprovals: Int
    /// Broker calls running now: runs with their deliveries, and write calls.
    package var runningAgentCalls: Int
    /// File uploads the agent has opened and not yet frozen or cancelled.
    package var openWriteSessions: Int
    /// A system authentication prompt is showing.
    package var managementAuthenticationActive: Bool

    package init(
        pendingApprovals: Int = 0,
        unusedApprovals: Int = 0,
        runningAgentCalls: Int = 0,
        openWriteSessions: Int = 0,
        managementAuthenticationActive: Bool = false
    ) {
        self.pendingApprovals = pendingApprovals
        self.unusedApprovals = unusedApprovals
        self.runningAgentCalls = runningAgentCalls
        self.openWriteSessions = openWriteSessions
        self.managementAuthenticationActive = managementAuthenticationActive
    }

    package static let idle = SoftwareUpdateActivity()
}

/// Decides whether Sparkle's relaunch must wait. An update never cancels,
/// denies or orphans a request, so any request in progress postpones it.
package enum SoftwareUpdateRelaunchPolicy {
    package enum Reason: Equatable, Sendable, CaseIterable {
        case pendingApproval
        case unusedApproval
        case runningAgentCall
        case openWriteSession
        case managementAuthentication
    }

    package static func reasonsToWait(_ activity: SoftwareUpdateActivity) -> [Reason] {
        var reasons: [Reason] = []
        if activity.pendingApprovals > 0 { reasons.append(.pendingApproval) }
        if activity.unusedApprovals > 0 { reasons.append(.unusedApproval) }
        if activity.runningAgentCalls > 0 { reasons.append(.runningAgentCall) }
        if activity.openWriteSessions > 0 { reasons.append(.openWriteSession) }
        if activity.managementAuthenticationActive { reasons.append(.managementAuthentication) }
        return reasons
    }

    package static func mustWait(_ activity: SoftwareUpdateActivity) -> Bool {
        !reasonsToWait(activity).isEmpty
    }
}

/// Holds Sparkle's relaunch until Ask Key is idle. Sparkle asks once; while
/// the relaunch waits, the gate samples the activity on a timer, so requests
/// that arrive meanwhile keep it waiting, and continues it exactly once.
@MainActor
package final class SoftwareUpdateRelaunchGate {
    /// Starts a repeating timer and returns the closure that stops it.
    package typealias StartTimer = @MainActor (
        _ interval: TimeInterval,
        _ tick: @escaping @MainActor () -> Void
    ) -> () -> Void

    private let activity: @MainActor () -> SoftwareUpdateActivity
    private let recheckInterval: TimeInterval
    private let startTimer: StartTimer
    private var postponedRelaunch: (() -> Void)?
    private var stopTimer: (() -> Void)?

    package init(
        recheckInterval: TimeInterval = 1,
        startTimer: @escaping StartTimer = SoftwareUpdateRelaunchGate.runLoopTimer,
        activity: @escaping @MainActor () -> SoftwareUpdateActivity
    ) {
        self.recheckInterval = recheckInterval
        self.startTimer = startTimer
        self.activity = activity
    }

    package var isPostponing: Bool { postponedRelaunch != nil }

    /// Returns `true` when the relaunch must wait; `relaunch` then runs once,
    /// after the app becomes idle. Returns `false` to relaunch now.
    package func postponeIfBusy(_ relaunch: @escaping () -> Void) -> Bool {
        guard SoftwareUpdateRelaunchPolicy.mustWait(activity()) else {
            cancelPostponedRelaunch()
            return false
        }
        // A newer request from Sparkle replaces the one already waiting.
        postponedRelaunch = relaunch
        if stopTimer == nil {
            stopTimer = startTimer(recheckInterval) { [weak self] in self?.recheck() }
        }
        return true
    }

    package func recheck() {
        guard let relaunch = postponedRelaunch,
              !SoftwareUpdateRelaunchPolicy.mustWait(activity()) else { return }
        cancelPostponedRelaunch()
        relaunch()
    }

    private func cancelPostponedRelaunch() {
        postponedRelaunch = nil
        stopTimer?()
        stopTimer = nil
    }

    package static func runLoopTimer(
        interval: TimeInterval,
        tick: @escaping @MainActor () -> Void
    ) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        // Common modes keep the check running while a menu or panel tracks events.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
