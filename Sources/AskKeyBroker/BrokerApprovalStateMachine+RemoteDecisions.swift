import Foundation

extension BrokerApprovalStateMachine {
    /// Applies a decision a paired approver signed (ADR 0014 → Broker remote
    /// path). The caller has verified it and supplies the request ID and
    /// capability from its outstanding entry and the captured operation
    /// request, which must match as for consumption.
    ///
    /// The verified approval-key signature stands in for the authentication a
    /// local read approval asks for, so the local authentication is never
    /// called. `revalidate` is the App's persisted-policy check; it runs
    /// outside the lock, like a local decision's, and never for a Deny, which
    /// grants nothing and does not wait for policy I/O. It has no default:
    /// the App applies decisions through `Vault.decideRemoteAgentApproval`,
    /// which also re-reads the approval flag. Every outcome is
    /// decided again inside the single locked transition from pending, where
    /// the approver must be in the active set with the recorded generation,
    /// Deny included. First decision wins: a later one finds the request no
    /// longer pending and changes nothing.
    package func decideRemotely(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        approver: BrokerRemoteApprover,
        code: BrokerRemoteDecisionCode,
        durationCeiling: TimeInterval,
        revalidate: () throws -> Void
    ) throws -> BrokerRemoteDecisionOutcome {
        if code != .deny {
            // Skip policy I/O for a decision that cannot apply anyway.
            let early: BrokerRemoteDecisionOutcome? = try mutate {
                guard isActiveApproverLocked(approver) else { return .approverInactive }
                expireUnconsumedLocked(now: clock())
                let (_, entry) = try remoteEntryLocked(requestID, capability, operationRequest)
                return preliminaryRemoteOutcomeLocked(entry)
            }
            if let early { return early }
            try revalidate()
        }
        return try mutate {
            // The approver check comes first, so a revoked approver learns
            // nothing about the request, not even whether it still exists.
            guard isActiveApproverLocked(approver) else { return .approverInactive }
            let now = clock()
            expireUnconsumedLocked(now: now)
            var (operationID, entry) = try remoteEntryLocked(requestID, capability, operationRequest)
            if let refusal = preliminaryRemoteOutcomeLocked(entry) { return refusal }
            var grantedSeconds: UInt64 = 0
            switch code {
            case .deny:
                guard durationCeiling == 0 else { return .notApplicable }
                entry.state = .denied
            case .allowOnce:
                guard durationCeiling == 0 else { return .notApplicable }
                entry.state = .approved
                entry.approvedByTimedAllowance = false
                entry.approvingDeviceName = approver.deviceName
            case .timedAllowance:
                // End Timed Allow on Lock forbids remote grants on the setting
                // alone, whatever the screen's state (ADR 0014).
                guard timedAllowanceEnabled, !endTimedAllowancesOnLock,
                      Self.validDuration(durationCeiling),
                      durationCeiling <= Self.maximumTimedAllowanceDuration else { return .notApplicable }
                let duration = min(durationCeiling, defaultTimedAllowance, Self.maximumTimedAllowanceDuration)
                guard let windowEnd = try? grantTimedAllowanceLocked(
                    to: &entry, duration: duration, at: now, group: nil, approvingDeviceName: approver.deviceName
                ) else { return .notApplicable }
                grantedSeconds = UInt64(windowEnd.timeIntervalSince(now).rounded(.down))
            }
            entry.remoteDecision = approver
            entriesByOperationID[operationID] = entry
            return .applied(entry.state, grantedSeconds: grantedSeconds)
        }
    }

    private func remoteEntryLocked(
        _ requestID: String, _ capability: String, _ operationRequest: BrokerApprovalOperationRequest
    ) throws -> (String, Entry) {
        guard let operationID = entriesByOperationID.first(where: {
            $0.value.requestID == requestID && $0.value.capability == capability
        })?.key, let entry = entriesByOperationID[operationID] else {
            throw BrokerApprovalError.requestNotFound
        }
        guard entry.request.matchesForConsumption(operationRequest) else {
            throw BrokerApprovalError.payloadMismatch
        }
        return (operationID, entry)
    }

    private func preliminaryRemoteOutcomeLocked(_ entry: Entry) -> BrokerRemoteDecisionOutcome? {
        guard entry.state == .pending else {
            return .notPending(entry.state, decidedBy: entry.remoteDecision?.pairingID)
        }
        guard entry.request.operation == .read, !entry.committing else { return .notApplicable }
        return nil
    }
}
