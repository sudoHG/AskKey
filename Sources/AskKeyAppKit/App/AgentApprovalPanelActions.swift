/// Window operations kept separate from request selection and authorization.
@MainActor
struct AgentApprovalPanelActions {
    let bringForward: () -> Void
    let dismiss: () -> Void
}
