import Foundation
import Observation
import SwiftUI

/// What the approval panel's footer says about the approvers (ADR 0014 →
/// Mac App, amended by #345). Without a hint the footer is unchanged.
enum RemoteApprovalFooterHint: Equatable {
    /// An eligible request waits for its 20-second send to an approver with
    /// room under its limit.
    case waiting(sendAt: Date)
    /// A copy saved to an approver's inbox is still outstanding.
    case sent
}

/// The footer's text before "Esc to decide later": one moving number at a
/// time (#344, decision 6). The send countdown takes the expiry's place
/// while the request waits; the expiry returns once a copy was saved.
enum RemoteApprovalFooter {
    static func text(_ hint: RemoteApprovalFooterHint?, expiresAt: Date?, now: Date) -> String {
        let expiry = FrozenCountdown.format(deadline: expiresAt, now: now)
        switch hint {
        case .waiting(let sendAt):
            guard let seconds = secondsUntilSend(sendAt, now: now) else { break }
            // "s" inflects in neither catalog language; the count still goes
            // through the plural lookup, so a language that inflects can add
            // plural variations to this key.
            return AppLanguage.localizedCount("iPhone can decide in %lld s", oneKey: "iPhone can decide in %lld s",
                                              count: seconds, language: AppLanguage.current)
        case .sent:
            return appLocalizedFormat("Also on iPhone · Expires in %@", expiry)
        case nil:
            break
        }
        return appLocalizedFormat("Expires in %@", expiry)
    }

    /// Whole seconds left before the send, rounded up, from 20 to 1; nil
    /// once the send is due, when the footer is unchanged until it is saved.
    static func secondsUntilSend(_ sendAt: Date, now: Date) -> Int? {
        let remaining = sendAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return min(Int(remaining.rounded(.up)), Int(DeviceCoordinator.remoteSendDelay))
    }

    /// The moment the footer's number counts toward.
    static func anchor(_ hint: RemoteApprovalFooterHint?, expiresAt: Date?) -> Date? {
        if case .waiting(let sendAt) = hint { return sendAt }
        return expiresAt
    }
}

/// Ticks once a second, just after each whole second before `anchor`, so
/// the footer's number changes when it should and not up to a second late.
struct RemoteApprovalFooterSchedule: TimelineSchedule {
    /// How long after a whole second each tick falls, so rounding the
    /// remaining time never lands on the boundary itself.
    static let offset: TimeInterval = 0.01
    let anchor: Date?

    /// The first entry is the latest tick at or before `startDate`.
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let base = (anchor ?? startDate).addingTimeInterval(Self.offset)
        var step = startDate.timeIntervalSince(base).rounded(.down)
        return AnyIterator {
            defer { step += 1 }
            return base.addingTimeInterval(step)
        }
    }
}

/// What the open approval panel shows about a paired iPhone (ADR 0014 → Mac
/// App): where its request went, for Details, what the footer says about
/// the approvers, and the approver's decision once it applied. The panel's
/// privacy check feeds it the coordinator's state on every tick and closes
/// the panel when `step` says so.
@Observable
final class RemoteApprovalPanelState {
    /// How long "Approved on" or "Denied on" stays on an unlocked screen.
    static let outcomeDuration: TimeInterval = 2
    /// How long the panel stays open after its request left pending while an
    /// approver's decision for it is still being applied.
    static let applyingGrace: TimeInterval = 3

    enum Step: Equatable {
        case keepOpen
        case close
    }

    let requestID: String
    /// The approvers the request went to; kept after the request left
    /// pending, when the coordinator drops it.
    private(set) var status: RemoteApprovalStatus?
    /// What the footer says about the approvers; nil once the request left
    /// pending or an approver's decision was recorded.
    private(set) var footer: RemoteApprovalFooterHint?
    /// The approver's decision that moved this request out of pending.
    private(set) var outcome: RemoteAppliedDecision?
    @ObservationIgnored private var outcomeShownAt: Date?
    @ObservationIgnored private var waitingSince: Date?

    init(requestID: String, status: RemoteApprovalStatus? = nil, footer: RemoteApprovalFooterHint? = nil) {
        self.requestID = requestID
        self.status = status
        self.footer = footer
    }

    /// Records the coordinator's latest decision when it decided this request.
    /// The footer's hint goes with it, so "Also on iPhone" never shows next
    /// to the approver's decision.
    func record(_ decision: RemoteAppliedDecision?, now: Date) {
        guard outcome == nil, let decision, decision.requestID == requestID else { return }
        outcome = decision
        outcomeShownAt = now
        footer = nil
    }

    /// One privacy check. A locked screen closes the panel at once; an
    /// approver's decision stays for `outcomeDuration`; a request that ended
    /// any other way closes the panel, after at most `applyingGrace` while a
    /// decision for it is being applied.
    func step(requestEnded: Bool, screenUnlocked: Bool, expired: Bool, now: Date,
              status: RemoteApprovalStatus?, footer: RemoteApprovalFooterHint? = nil,
              lastDecision: RemoteAppliedDecision?, applying: Bool) -> Step {
        if !requestEnded, status != self.status { self.status = status }
        record(lastDecision, now: now)
        let footer = requestEnded || outcome != nil ? nil : footer
        if footer != self.footer { self.footer = footer }
        guard screenUnlocked else { return .close }
        if let shownAt = outcomeShownAt {
            return now.timeIntervalSince(shownAt) >= Self.outcomeDuration ? .close : .keepOpen
        }
        if expired { return .close }
        guard requestEnded else { return .keepOpen }
        guard applying else { return .close }
        let since = waitingSince ?? now
        waitingSince = since
        return now.timeIntervalSince(since) >= Self.applyingGrace ? .close : .keepOpen
    }

    /// Whether the panel is showing, or about to show, an approver's decision,
    /// so a new request must wait until it closes.
    func holdsPanel(screenUnlocked: Bool, lastDecision: RemoteAppliedDecision?, applying: Bool) -> Bool {
        guard screenUnlocked else { return false }
        return outcome != nil || lastDecision?.requestID == requestID || applying
    }
}
