import Foundation

/// Read-only views of the remote approval state for the approval panel and
/// the pending-requests list (ADR 0014 → Mac App). Nothing here changes the
/// coordinator or exposes request content.
extension DeviceCoordinator {
    /// Whether a verified decision from an approver is being applied to
    /// `requestID`. The Broker may already have moved the request out of
    /// pending while `lastRemoteDecision` is not set yet.
    func isApplyingRemoteDecision(to requestID: String) -> Bool {
        (remoteRequests[requestID]?.applying ?? 0) > 0
    }

    /// Whether the request was saved to at least one approver's inbox.
    func wasSentToApprover(_ requestID: String) -> Bool {
        remoteApprovals[requestID]?.approvers.contains { $0.sentAt != nil } == true
    }
}
