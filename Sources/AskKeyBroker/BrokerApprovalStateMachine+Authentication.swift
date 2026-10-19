import Foundation

extension BrokerApprovalStateMachine {
    package func configureAgentAccessPolicy(
        readAuthenticationEnabled: Bool,
        timedAllowanceEnabled: Bool,
        timedAllowanceDuration: TimeInterval
    ) {
        let revoked: ([String], @Sendable (String) -> Void)? = mutate {
            self.readAuthenticationEnabled = readAuthenticationEnabled
            self.timedAllowanceEnabled = timedAllowanceEnabled
            defaultTimedAllowance = Self.validDuration(timedAllowanceDuration) ? timedAllowanceDuration : 30 * 60
            return timedAllowanceEnabled ? nil : revokeAllTimedAllowancesLocked()
        }
        if let revoked {
            revoked.0.forEach(revoked.1)
        }
    }

    func setReadAuthenticationEnabled(_ enabled: Bool) {
        mutate { readAuthenticationEnabled = enabled }
    }

    public func configureAuthentication(
        _ authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool
    ) {
        observerLock.lock()
        self.authenticate = authenticate
        observerLock.unlock()
    }
}
