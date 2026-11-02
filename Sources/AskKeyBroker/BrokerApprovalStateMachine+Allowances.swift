import Foundation

extension BrokerApprovalStateMachine {
    /// Session events and final timed grants share the same lock. Advance even
    /// with no allowances, so an in-flight decision cannot restore authority.
    /// sleeping: true enters sleep, false reports didWake, nil leaves it unchanged.
    @discardableResult
    package func updateTimedAllowanceSession(active: Bool, endOnLock: Bool, suspended: Bool = false,
                                           sleeping: Bool? = nil, sleepOffsetUpperBound: UInt64? = nil) -> Bool {
        let revoked: ([String], @Sendable (String) -> Void)? = mutate {
            timedAllowanceSessionRevision = UUID()
            timedAllowanceSessionActive = active
            timedAllowanceSessionSuspended = suspended
            if let sleeping {
                timedAllowanceSessionSleeping = sleeping
                timedAllowanceSleepOffsetAtSleep = sleeping ? (sleepOffsetUpperBound ?? timedAllowanceSleepOffset().upper) : nil
            } else {
                clearTimedAllowanceSleepIfProvenLocked(unlocked: active)
            }
            guard sleeping == true || !active, endOnLock || endTimedAllowancesOnLock else { return nil }
            timedAllowanceSessionGeneration = UUID()
            return revokeAllTimedAllowancesLocked()
        }
        if let revoked { revoked.0.forEach(revoked.1) }
        return revoked != nil
    }

    func setTimedAllowanceEnabled(_ enabled: Bool) {
        mutate { timedAllowanceEnabled = enabled }
    }

    func updateDefaultTimedAllowance(_ duration: TimeInterval) {
        mutate {
            defaultTimedAllowance = Self.validDuration(duration) ? duration : 30 * 60
        }
    }

    /// App-only projection; the public Broker RPC surface does not expose it.
    public func timedAllowanceDeadline(credentialID: String) -> Date? {
        mutate {
            expireTimedAllowancesLocked(now: clock())
            return timedAllowances.values.first { $0.members.contains { $0.credentialID == credentialID } }?.expiresAt
        }
    }

    public func activeTimedAllowances() -> [BrokerTimedAllowance] {
        mutate {
            expireTimedAllowancesLocked(now: clock())
            return timedAllowances.values.sorted { $0.id.uuidString < $1.id.uuidString }
        }
    }

    func allowanceLocked(credentialID: String, digest: String?) -> BrokerTimedAllowance? {
        timedAllowances.values.first { allowance in
            allowance.members.contains { $0.credentialID == credentialID && $0.metadataDigest == (digest ?? "") }
        }
    }

    func removeAllowanceMemberLocked(credentialID: String) {
        for id in Array(timedAllowances.keys) {
            timedAllowances[id]?.members.removeAll { $0.credentialID == credentialID }
            if timedAllowances[id]?.members.isEmpty == true { timedAllowances.removeValue(forKey: id) }
        }
    }

    /// Replacement ends older timed authority before the new membership is installed.
    /// Once-only approvals and credentials outside the replacement retain their authority.
    func invalidateReplacedTimedAuthorizationsLocked(credentialIDs: Set<String>) {
        for id in credentialIDs { invalidateRuntimeAuthorizationsLocked(credentialID: id, timedOnly: true) }
        for operationID in entriesByOperationID.keys {
            guard var entry = entriesByOperationID[operationID],
                  credentialIDs.contains(entry.request.credentialID),
                  entry.state == .approved, !entry.committing,
                  entry.approvedByTimedAllowance else { continue }
            entry.state = .cancelled
            entriesByOperationID[operationID] = entry
        }
    }

    /// A run may already be waiting for several members when the first card is approved.
    func approvePendingGroupReadsLocked(_ allowance: BrokerTimedAllowance) {
        for operationID in entriesByOperationID.keys {
            guard var entry = entriesByOperationID[operationID], entry.state == .pending,
                  entry.request.operation == .read,
                  allowance.members.contains(where: {
                      $0.credentialID == entry.request.credentialID && $0.metadataDigest == entry.request.readProjectionDigest
                  }) else { continue }
            entry.state = .approved
            entry.approvedByTimedAllowance = true
            entry.expiresAt = min(entry.expiresAt, allowance.expiresAt)
            entriesByOperationID[operationID] = entry
        }
    }

    package func withdrawGroupAllowance(requestID: String, capability: String) {
        mutate {
            guard let entry = matchingEntry(requestID: requestID, capability: capability) else { return }
            entriesByOperationID[entry.request.operationID]?.groupAllowanceSnapshot = nil
        }
    }

    @discardableResult
    public func revokeTimedAllowance(credentialID: String) -> Bool {
        revokeTimedAllowance { $0.members.contains { $0.credentialID == credentialID } }
    }

    /// List actions target the displayed grant even if its membership has changed.
    @discardableResult
    public func revokeTimedAllowance(id: UUID) -> Bool {
        revokeTimedAllowance { $0.id == id }
    }

    private func revokeTimedAllowance(matching matches: (BrokerTimedAllowance) -> Bool) -> Bool {
        let result: ([String], @Sendable (String) -> Void)? = mutate {
            guard let allowance = timedAllowances.values.first(where: matches) else { return nil }
            timedAllowances.removeValue(forKey: allowance.id)
            let ids = allowance.members.map(\.credentialID)
            for id in ids { invalidateRuntimeAuthorizationsLocked(credentialID: id, timedOnly: true) }
            for operationID in entriesByOperationID.keys {
                guard var entry = entriesByOperationID[operationID],
                      ids.contains(entry.request.credentialID),
                      entry.state == .approved,
                      !entry.committing,
                      entry.approvedByTimedAllowance else { continue }
                entry.state = .cancelled
                entriesByOperationID[operationID] = entry
            }
            return (ids, timedAllowanceRevoked)
        }
        if let result { result.0.forEach(result.1) }
        return result != nil
    }

    public func revokeAllTimedAllowances() {
        let result = mutate { revokeAllTimedAllowancesLocked() }
        result.0.forEach(result.1)
    }

    func revokeAllTimedAllowancesLocked() -> ([String], @Sendable (String) -> Void) {
        let credentialIDs = timedAllowances.values.flatMap { $0.members.map(\.credentialID) }
        timedAllowances.removeAll()
        invalidateRuntimeAuthorizationsLocked(timedOnly: true)
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

    public func setTimedAllowanceRevokedHandler(
        _ handler: @escaping @Sendable (String) -> Void
    ) {
        mutate { timedAllowanceRevoked = handler }
    }
}
