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
                default: throw Self.lostDecisionError(entry, otherwise: .invalidDecision)
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
            ($0, readAuthenticationEnabled, timedAllowanceEnabled, defaultTimedAllowance,
             timedAllowanceSessionGeneration)
        }
        let entry = context.0
        guard entry.state == .pending else { throw Self.lostDecisionError(entry, otherwise: .invalidDecision) }
        let timedAllowanceDuration: TimeInterval?
        if let duration = decision.timedDuration {
            guard context.2, entry.request.operation == .read else { throw BrokerApprovalError.invalidDecision }
            if let duration, !Self.validDuration(duration) { throw BrokerApprovalError.invalidDecision }
            timedAllowanceDuration = min(duration ?? context.3, Self.maximumTimedAllowanceDuration)
        } else {
            timedAllowanceDuration = nil
        }
        if case .timedAllowGroup = decision {
            guard let snapshot = entry.groupAllowanceSnapshot,
                  !snapshot.groupName.isEmpty, !snapshot.members.isEmpty,
                  Set(snapshot.members.map(\.credentialID)).count == snapshot.members.count,
                  snapshot.members.contains(where: {
                      $0.credentialID == entry.request.credentialID && $0.metadataDigest == entry.request.readProjectionDigest
                  }), snapshot.members.allSatisfy({ $0.expiresAt.map { $0 > now } ?? true }) else {
                throw BrokerApprovalError.invalidDecision
            }
        }
        let requiresAuthentication = decision != .deny && (entry.request.operation != .read || context.1)
        if requiresAuthentication {
            let purpose: BrokerAuthenticationPurpose = entry.request.operation == .read
                ? .readApproval
                : .writeApproval
            observerLock.lock()
            let authenticate = self.authenticate
            observerLock.unlock()
            guard authenticate(purpose) else {
                // The App ends an open authentication once the request stops
                // being pending; a remote decision that won is not a failure.
                // A plain read: no expiry pass, screen sample or observer.
                lock.lock()
                let current = matchingEntry(requestID: requestID, capability: capability)
                lock.unlock()
                throw current.map { Self.lostDecisionError($0, otherwise: .authenticationFailed) }
                    ?? BrokerApprovalError.authenticationFailed
            }
        }
        try revalidate()
        let verifiedAt = decision == .deny ? now : max(now, clock())
        return try updateEntry(requestID: requestID, capability: capability, now: verifiedAt) { entry in
            guard entry.state == .pending else { throw Self.lostDecisionError(entry, otherwise: .invalidDecision) }
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
            case .timedAllow, .timedAllowGroup:
                // Settings may have changed while system authentication ran.
                guard timedAllowanceEnabled else { throw BrokerApprovalError.invalidDecision }
                guard timedAllowanceSessionGeneration == context.4,
                      !endTimedAllowancesOnLock || timedAllowanceSessionPermitsGrantLocked() else {
                    throw BrokerApprovalError.invalidDecision
                }
                guard let timedAllowanceDuration else { throw BrokerApprovalError.invalidDecision }
                var group: BrokerGroupAllowanceSnapshot?
                if case .timedAllowGroup = decision {
                    guard let snapshot = entry.groupAllowanceSnapshot,
                          snapshot == context.0.groupAllowanceSnapshot else { throw BrokerApprovalError.invalidDecision }
                    group = snapshot
                }
                try grantTimedAllowanceLocked(to: &entry, duration: min(timedAllowanceDuration, defaultTimedAllowance),
                                              at: verifiedAt, group: group, approvingDeviceName: nil)
            }
        }
    }

    /// Installs one timed allowance and approves `entry` under it. The caller
    /// has checked the settings and the session; nothing changes on a throw.
    /// Returns the allowance's end.
    @discardableResult
    func grantTimedAllowanceLocked(
        to entry: inout Entry, duration: TimeInterval, at verifiedAt: Date,
        group snapshot: BrokerGroupAllowanceSnapshot?, approvingDeviceName: String?
    ) throws -> Date {
        let windowEnd = verifiedAt.addingTimeInterval(duration)
        var effectiveWindowEnd = entry.credentialExpiresAt.map {
            min(windowEnd, $0)
        } ?? windowEnd
        let members: [BrokerGroupAllowanceSnapshot.Member]
        if let snapshot {
            members = snapshot.members
            effectiveWindowEnd = min(effectiveWindowEnd, snapshot.earliestExpiry ?? effectiveWindowEnd)
        } else {
            members = [.init(credentialID: entry.request.credentialID,
                name: entry.trustedCredentialName ?? entry.request.credentialName ?? entry.request.targetID,
                metadataDigest: entry.request.readProjectionDigest ?? "", expiresAt: entry.credentialExpiresAt)]
        }
        guard effectiveWindowEnd > verifiedAt else { throw BrokerApprovalError.invalidDecision }
        invalidateReplacedTimedAuthorizationsLocked(credentialIDs: Set(members.map(\.credentialID)))
        for member in members { removeAllowanceMemberLocked(credentialID: member.credentialID) }
        let allowance = BrokerTimedAllowance(groupName: snapshot?.groupName, members: members,
                                             expiresAt: effectiveWindowEnd, approvingDeviceName: approvingDeviceName)
        timedAllowances[allowance.id] = allowance
        if snapshot != nil { approvePendingGroupReadsLocked(allowance) }
        entry.expiresAt = min(entry.expiresAt, effectiveWindowEnd)
        entry.state = .approved
        entry.approvedByTimedAllowance = true
        entry.approvingDeviceName = approvingDeviceName
        return effectiveWindowEnd
    }

    /// A local decision that finds the request decided by a remote approver
    /// ends "decided elsewhere" instead of with an error (ADR 0014).
    static func lostDecisionError(_ entry: Entry, otherwise error: BrokerApprovalError) -> BrokerApprovalError {
        entry.state != .pending && entry.remoteDecision != nil ? .decidedElsewhere : error
    }
}
