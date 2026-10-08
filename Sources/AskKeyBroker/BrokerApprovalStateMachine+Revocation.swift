import Foundation

extension BrokerApprovalStateMachine {
    @discardableResult
    public func cancelPending(credentialID: String) -> Int {
        cancelPending(credentialID: credentialID, forExpiry: false)
    }

    /// Rename/delete-only members do not impose a credential expiry deadline.
    @discardableResult
    public func cancelPendingForExpiry(credentialID: String) -> Int {
        cancelPending(credentialID: credentialID, forExpiry: true)
    }

    private func cancelPending(credentialID: String, forExpiry: Bool) -> Int {
        mutate {
            let now = clock()
            if forExpiry { expireUnconsumedLocked(now: now) }
            timedAllowances.removeValue(forKey: credentialID)
            invalidateRuntimeAuthorizationsLocked(credentialID: credentialID)
            var count = 0
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      (entry.request.credentialID == credentialID
                        || entry.request.organizationCredentialIDs?.contains(credentialID) == true),
                      !entry.committing,
                      entry.state == .pending || entry.state == .approved else { continue }
                if forExpiry, entry.request.operation == .organize, entry.expiresAt > now { continue }
                entry.state = .cancelled
                entriesByOperationID[operationID] = entry
                count += 1
            }
            return count
        }
    }

    public func pauseAndCancelAll() {
        mutate {
            paused = true
            timedAllowances.removeAll()
            invalidateRuntimeAuthorizationsLocked()
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      !entry.committing,
                      entry.state == .pending || entry.state == .approved else { continue }
                entry.state = .cancelled
                entriesByOperationID[operationID] = entry
            }
        }
    }

    public func resume() {
        mutate { paused = false }
    }
}
