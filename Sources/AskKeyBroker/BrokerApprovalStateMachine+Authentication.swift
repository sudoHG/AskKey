import Foundation

extension BrokerApprovalStateMachine {
    package func configureAgentAccessPolicy(
        readAuthenticationEnabled: Bool,
        timedAllowanceEnabled: Bool,
        timedAllowanceDuration: TimeInterval,
        endTimedAllowancesOnLock: Bool = false
    ) {
        let revoked: ([String], @Sendable (String) -> Void)? = mutate(endOnLock: endTimedAllowancesOnLock) {
            let duration = Self.validDuration(timedAllowanceDuration) ? timedAllowanceDuration : 30 * 60
            if self.endTimedAllowancesOnLock != endTimedAllowancesOnLock {
                timedAllowanceSessionRevision = UUID()
            }
            self.readAuthenticationEnabled = readAuthenticationEnabled
            self.timedAllowanceEnabled = timedAllowanceEnabled
            self.endTimedAllowancesOnLock = endTimedAllowancesOnLock
            defaultTimedAllowance = duration
            if endTimedAllowancesOnLock,
               !timedAllowanceScreenSampleFailed || timedAllowanceSessionFence.snapshot.pending,
               !timedAllowanceSessionPermitsGrantLocked() {
                timedAllowanceSessionGeneration = UUID()
                return revokeAllTimedAllowancesLocked()
            }
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
