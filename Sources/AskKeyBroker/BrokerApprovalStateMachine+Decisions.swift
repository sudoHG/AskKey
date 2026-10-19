import Foundation

extension BrokerApprovalStateMachine {
    package func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        try decide(requestID: requestID, capability: capability, decision: decision, revalidate: {})
    }

    /// App-only persisted-policy check. It may quiesce the state machine, so it
    /// must run outside its lock, including after a blocking authentication.
    package func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision,
        revalidate: () throws -> Void
    ) throws -> BrokerApprovalTicket {
        if decision == .deny {
            // Denial grants no authority and must never wait for policy I/O.
            return try updateEntry(requestID: requestID, capability: capability, now: clock()) { entry in
                switch entry.state {
                case .pending: entry.state = .denied
                case .denied, .cancelled, .expired: break
                default: throw BrokerApprovalError.invalidDecision
                }
            }
        }
        return try decide(requestID: requestID, capability: capability, decision: decision,
                          now: clock(), revalidate: revalidate)
    }

    /// Test seam. Production callers cannot supply time.
    func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision,
        now: Date,
        revalidate: () throws -> Void = {}
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
        try revalidate()
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
                let duration = min(timedAllowanceDuration, defaultTimedAllowance)
                let windowEnd = verifiedAt.addingTimeInterval(duration)
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
