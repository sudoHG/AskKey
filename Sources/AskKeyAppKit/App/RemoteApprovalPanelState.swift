import Foundation
import Observation

/// What the open approval panel shows about a paired iPhone (ADR 0014 → Mac
/// App): where its request went, for Details, and the approver's decision
/// once it applied. The panel's privacy check feeds it the coordinator's
/// state on every tick and closes the panel when `step` says so.
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
    /// The approver's decision that moved this request out of pending.
    private(set) var outcome: RemoteAppliedDecision?
    @ObservationIgnored private var outcomeShownAt: Date?
    @ObservationIgnored private var waitingSince: Date?

    init(requestID: String, status: RemoteApprovalStatus? = nil) {
        self.requestID = requestID
        self.status = status
    }

    /// Records the coordinator's latest decision when it decided this request.
    func record(_ decision: RemoteAppliedDecision?, now: Date) {
        guard outcome == nil, let decision, decision.requestID == requestID else { return }
        outcome = decision
        outcomeShownAt = now
    }

    /// One privacy check. A locked screen closes the panel at once; an
    /// approver's decision stays for `outcomeDuration`; a request that ended
    /// any other way closes the panel, after at most `applyingGrace` while a
    /// decision for it is being applied.
    func step(requestEnded: Bool, screenUnlocked: Bool, expired: Bool, now: Date,
              status: RemoteApprovalStatus?, lastDecision: RemoteAppliedDecision?, applying: Bool) -> Step {
        if !requestEnded, status != self.status { self.status = status }
        record(lastDecision, now: now)
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
