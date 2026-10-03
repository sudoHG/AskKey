enum AgentApprovalPresentationPlan: Equatable {
    case lockedReminder(title: String, body: String)
    case detailedConfirmation
}
