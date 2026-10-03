import Foundation

extension BrokerApprovalStateMachine {
    public func updateDefaultTimedAllowance(_ duration: TimeInterval) {
        mutate {
            defaultTimedAllowance = Self.validDuration(duration) ? duration : 30 * 60
        }
    }

    /// App-only projection; the public Broker RPC surface does not expose it.
    public func timedAllowanceDeadline(credentialID: String) -> Date? {
        mutate {
            expireTimedAllowancesLocked(now: clock())
            return timedAllowances[credentialID]
        }
    }

    @discardableResult
    public func revokeTimedAllowance(credentialID: String) -> Bool {
        let handler: (@Sendable (String) -> Void)? = mutate {
            guard timedAllowances.removeValue(forKey: credentialID) != nil else { return nil }
            invalidateRuntimeAuthorizationsLocked(credentialID: credentialID)
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      entry.request.credentialID == credentialID,
                      entry.state == .approved,
                      !entry.committing,
                      entry.approvedByTimedAllowance else { continue }
                entry.state = .cancelled
                entriesByOperationID[operationID] = entry
            }
            return timedAllowanceRevoked
        }
        handler?(credentialID)
        return handler != nil
    }

    public func revokeAllTimedAllowances() {
        let result: ([String], @Sendable (String) -> Void) = mutate {
            let credentialIDs = Array(timedAllowances.keys)
            timedAllowances.removeAll()
            invalidateRuntimeAuthorizationsLocked()
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      entry.state == .approved,
                      !entry.committing,
                      entry.approvedByTimedAllowance else { continue }
                entry.state = .cancelled
                entriesByOperationID[operationID] = entry
            }
            return (credentialIDs, timedAllowanceRevoked)
        }
        result.0.forEach(result.1)
    }

    public func setTimedAllowanceRevokedHandler(
        _ handler: @escaping @Sendable (String) -> Void
    ) {
        mutate { timedAllowanceRevoked = handler }
    }
}
