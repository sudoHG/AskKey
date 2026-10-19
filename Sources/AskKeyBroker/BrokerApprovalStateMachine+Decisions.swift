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
            ($0, readAuthenticationEnabled, timedAllowanceEnabled, defaultTimedAllowance)
        }
        let entry = context.0
        guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
        let timedAllowanceDuration: TimeInterval?
        if case let .timedAllow(duration) = decision {
            guard context.2, entry.request.operation == .read else { throw BrokerApprovalError.invalidDecision }
            if let duration, !Self.validDuration(duration) { throw BrokerApprovalError.invalidDecision }
            timedAllowanceDuration = min(duration ?? context.3, Self.maximumTimedAllowanceDuration)
        } else {
            timedAllowanceDuration = nil
        }
        let requiresAuthentication = decision != .deny && (entry.request.operation != .read || context.1)
        if requiresAuthentication {
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
            guard decision == .deny || entry.request.operation != .read
                    || !readAuthenticationEnabled || requiresAuthentication else {
                throw BrokerApprovalError.authenticationFailed
            }
            switch decision {
            case .deny:
                entry.state = .denied
            case .once:
                entry.state = .approved
                entry.approvedByTimedAllowance = false
            case .timedAllow:
                // Settings may have changed while system authentication ran.
                guard timedAllowanceEnabled else { throw BrokerApprovalError.invalidDecision }
                guard let timedAllowanceDuration else { throw BrokerApprovalError.invalidDecision }
                let windowEnd = verifiedAt.addingTimeInterval(timedAllowanceDuration)
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
