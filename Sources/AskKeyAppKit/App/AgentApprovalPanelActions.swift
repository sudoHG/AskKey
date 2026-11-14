/// Window operations kept separate from request selection and authorization.
@MainActor
struct AgentApprovalPanelActions {
    let bringForward: () -> Void
    let dismiss: () -> Void
    /// Whether the panel shows, or is about to show, a paired iPhone's
    /// decision for its request; it then closes itself (ADR 0014 → Mac App).
    var showsRemoteOutcome: () -> Bool = { false }
}
