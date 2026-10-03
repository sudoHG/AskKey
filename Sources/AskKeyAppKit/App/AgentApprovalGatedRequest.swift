enum AgentApprovalGatedRequest<Request> {
    case lockedReminder(title: String, body: String)
    case detailed(Request?)
}
