import Foundation

extension BrokerApprovalStateMachine {
    public func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        try decide(requestID: requestID, capability: capability, decision: decision, now: clock())
    }

    /// Test seam. Production callers cannot supply time.
    func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision,
        now: Date
    ) throws -> BrokerApprovalTicket {
        let context = try withEntry(requestID: requestID, capability: capability, now: now) {
            ($0, readAuthenticationEnabled)
        }
        let entry = context.0
        guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
        if case let .timedAllow(duration) = decision {
            guard entry.request.operation == .read else { throw BrokerApprovalError.invalidDecision }
            if let duration, !Self.validDuration(duration) { throw BrokerApprovalError.invalidDecision }
        }
        if decision != .deny,
           entry.request.operation != .read || context.1 {
            let purpose: BrokerAuthenticationPurpose = entry.request.operation == .read
                ? .readApproval
                : .writeApproval
            observerLock.lock()
            let authenticate = self.authenticate
            observerLock.unlock()
            guard authenticate(purpose) else { throw BrokerApprovalError.authenticationFailed }
        }
        let verifiedAt = decision == .deny ? now : max(now, clock())

        return try updateEntry(requestID: requestID, capability: capability, now: verifiedAt) { entry in
            guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
            switch decision {
            case .deny:
                entry.state = .denied
            case .once:
                entry.state = .approved
                entry.approvedByTimedAllowance = false
            case let .timedAllow(duration):
                let windowEnd = verifiedAt.addingTimeInterval(duration ?? defaultTimedAllowance)
                let effectiveWindowEnd = entry.credentialExpiresAt.map {
                    min(windowEnd, $0)
                } ?? windowEnd
                timedAllowances[entry.request.credentialID] = effectiveWindowEnd
                entry.expiresAt = min(entry.expiresAt, effectiveWindowEnd)
                entry.state = .approved
                entry.approvedByTimedAllowance = true
            }
        }
    }
}
