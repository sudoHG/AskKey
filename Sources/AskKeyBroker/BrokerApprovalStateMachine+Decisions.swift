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
            ($0, readAuthenticationEnabled, timedAllowanceEnabled, defaultTimedAllowance,
             timedAllowanceSessionGeneration)
        }
        let entry = context.0
        guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
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
            case .timedAllow, .timedAllowGroup:
                // Settings may have changed while system authentication ran.
                guard timedAllowanceEnabled else { throw BrokerApprovalError.invalidDecision }
                guard timedAllowanceSessionGeneration == context.4,
                      !endTimedAllowancesOnLock || timedAllowanceSessionPermitsGrantLocked() else {
                    throw BrokerApprovalError.invalidDecision
                }
                guard let timedAllowanceDuration else { throw BrokerApprovalError.invalidDecision }
                let duration = min(timedAllowanceDuration, defaultTimedAllowance)
                let windowEnd = verifiedAt.addingTimeInterval(duration)
                var effectiveWindowEnd = entry.credentialExpiresAt.map {
                    min(windowEnd, $0)
                } ?? windowEnd
                let members: [BrokerGroupAllowanceSnapshot.Member]
                let groupName: String?
                if case .timedAllowGroup = decision {
                    guard let snapshot = entry.groupAllowanceSnapshot,
                          snapshot == context.0.groupAllowanceSnapshot else { throw BrokerApprovalError.invalidDecision }
                    members = snapshot.members
                    groupName = snapshot.groupName
                    effectiveWindowEnd = min(effectiveWindowEnd, snapshot.earliestExpiry ?? effectiveWindowEnd)
                } else {
                    members = [.init(credentialID: entry.request.credentialID,
                        name: entry.trustedCredentialName ?? entry.request.credentialName ?? entry.request.targetID,
                        metadataDigest: entry.request.readProjectionDigest ?? "", expiresAt: entry.credentialExpiresAt)]
                    groupName = nil
                }
                guard effectiveWindowEnd > verifiedAt else { throw BrokerApprovalError.invalidDecision }
                for member in members { removeAllowanceMemberLocked(credentialID: member.credentialID) }
                let allowance = BrokerTimedAllowance(groupName: groupName, members: members, expiresAt: effectiveWindowEnd)
                timedAllowances[allowance.id] = allowance
                if groupName != nil { approvePendingGroupReadsLocked(allowance) }
                entry.expiresAt = min(entry.expiresAt, effectiveWindowEnd)
                entry.state = .approved
                entry.approvedByTimedAllowance = true
            }
        }
    }
}
