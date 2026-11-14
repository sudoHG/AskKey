import AskKeyBroker

/// How the App treats a decision made on the Mac that did not apply.
enum LocalApprovalDecision {
    /// Whether the error is shown. A local decision that lost to a paired
    /// approver's decision, which moved the request out of pending first,
    /// is not a failure (ADR 0014 → First decision wins).
    static func showsError(_ error: Error) -> Bool {
        (error as? BrokerApprovalError) != .decidedElsewhere
    }
}
