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

    /// What the approval panel's footer says about the approvers (ADR 0014 →
    /// Mac App, amended by #345), from the same state the sending follows:
    /// `.waiting` while the request waits for its 20-second send with the
    /// send time ahead, before its deadline, still eligible and with an
    /// active approver below its outstanding limit; `.sent` while a copy
    /// saved to an approver's inbox (Details' "Sent to") is undecided and
    /// open; nil otherwise, including while sealing, while a first send
    /// retries, when every approver is full and once every copy closed.
    func remoteFooterHint(for requestID: String) -> RemoteApprovalFooterHint? {
        guard let track = remoteRequests[requestID], track.ended == nil else { return nil }
        switch track.phase {
        case .waiting(let sendAt):
            guard sendAt > now, let deadline = track.deadline, deadline > sendAt, remoteSendingAllowed,
                  activeApprovers(in: listedDevices).contains(where: {
                      outstandingCount(for: $0.device.deviceID) < Self.maximumOutstandingPerApprover
                  }) else { return nil }
            return .waiting(sendAt: sendAt)
        case .sent:
            return track.entries.contains { $0.sentAt != nil && !$0.decided } ? .sent : nil
        case .sending, .stayingOnMac:
            return nil
        }
    }
}
