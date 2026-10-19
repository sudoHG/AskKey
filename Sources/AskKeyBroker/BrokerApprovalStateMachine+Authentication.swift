import Foundation

extension BrokerApprovalStateMachine {
    package func configureAgentAccessPolicy(
        readAuthenticationEnabled: Bool,
        timedAllowanceEnabled: Bool,
        timedAllowanceDuration: TimeInterval
    ) {
        mutate {
            self.readAuthenticationEnabled = readAuthenticationEnabled
            self.timedAllowanceEnabled = timedAllowanceEnabled
            defaultTimedAllowance = Self.validDuration(timedAllowanceDuration) ? timedAllowanceDuration : 30 * 60
        }
    }

    public func setReadAuthenticationEnabled(_ enabled: Bool) {
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
