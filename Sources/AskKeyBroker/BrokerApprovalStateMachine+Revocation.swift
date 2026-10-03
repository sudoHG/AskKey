import Foundation

extension BrokerApprovalStateMachine {
    @discardableResult
    public func cancelPending(credentialID: String) -> Int {
        mutate {
            timedAllowances.removeValue(forKey: credentialID)
            invalidateRuntimeAuthorizationsLocked(credentialID: credentialID)
            var count = 0
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      entry.request.credentialID == credentialID,
                      !entry.committing,
                      entry.state == .pending || entry.state == .approved else { continue }
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
