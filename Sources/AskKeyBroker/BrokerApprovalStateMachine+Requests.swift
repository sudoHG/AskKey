import Foundation

extension BrokerApprovalStateMachine {
    public func submit(
        _ request: BrokerApprovalOperationRequest,
        trustedCredentialDeadline: BrokerCredentialDeadline,
        trustedCredentialName: String? = nil
    ) throws -> BrokerApprovalTicket {
        try submit(
            request,
            trustedCredentialDeadline: trustedCredentialDeadline,
            trustedCredentialName: trustedCredentialName,
            now: clock()
        )
    }

    /// Returns a retained terminal result for an exact network retransmission
    /// without requiring the caller-known payload to be frozen again.
    public func terminalRetransmission(
        operationID: String,
        payloadDigest: String
    ) throws -> BrokerApprovalTicket? {
        try mutate {
            guard !operationID.isEmpty,
                  operationID.utf8.count <= BrokerLimits.maximumFieldBytes,
                  payloadDigest.utf8.count == 64,
                  payloadDigest.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
                  }) else {
                throw BrokerApprovalError.invalidRequest
            }
            expireUnconsumedLocked(now: clock())
            guard var existing = entriesByOperationID[operationID] else { return nil }
            guard existing.request.constantTimeEqual(
                existing.request.retransmissionDigest ?? existing.request.payloadDigest,
                payloadDigest
            ) else {
                throw BrokerApprovalError.payloadMismatch
            }
            guard existing.state != .pending, existing.state != .approved else { return nil }
            existing.retryCount += 1
            entriesByOperationID[operationID] = existing
            return ticket(for: existing)
        }
    }

    /// Test seam. Production callers cannot supply time.
    func submit(
        _ request: BrokerApprovalOperationRequest,
        now: Date
    ) throws -> BrokerApprovalTicket {
        try submit(request, trustedCredentialDeadline: .none, now: now)
    }

    /// Test seam. Production callers must supply the Vault-derived deadline.
    func submit(_ request: BrokerApprovalOperationRequest) throws -> BrokerApprovalTicket {
        try submit(request, trustedCredentialDeadline: .none, now: clock())
    }

    private func submit(
        _ request: BrokerApprovalOperationRequest,
        trustedCredentialDeadline: BrokerCredentialDeadline,
        trustedCredentialName: String? = nil,
        now: Date
    ) throws -> BrokerApprovalTicket {
        try mutate {
            guard Self.valid(request) else { throw BrokerApprovalError.invalidRequest }
            guard trustedCredentialDeadline.date.map({
                $0.timeIntervalSinceReferenceDate.isFinite
            }) ?? true else {
                throw BrokerApprovalError.invalidRequest
            }
            guard !paused else { throw BrokerApprovalError.agentAccessPaused }
            expireUnconsumedLocked(now: now)
            expireTimedAllowancesLocked(now: now)
            if var existing = entriesByOperationID[request.operationID] {
                guard existing.request == request,
                      existing.credentialExpiresAt == trustedCredentialDeadline.date else {
                    throw BrokerApprovalError.payloadMismatch
                }
                existing.retryCount += 1
                entriesByOperationID[request.operationID] = existing
                return ticket(for: existing)
            }
            let activeCount = entriesByOperationID.values.reduce(into: 0) {
                if $1.state == .pending || $1.state == .approved { $0 += 1 }
            }
            guard activeCount < BrokerLimits.maximumPendingApprovalRequests else {
                throw BrokerApprovalError.capacityReached
            }
            let allowanceEnd = request.operation == .read
                ? timedAllowances[request.credentialID]
                : nil
            let state: BrokerRequestState = allowanceEnd != nil ? .approved : .pending
            try makeRetentionRoom()
            let requestDeadline = now.addingTimeInterval(requestTTL)
            let credentialDeadline = trustedCredentialDeadline.date ?? requestDeadline
            let expiresAt = min(
                requestDeadline,
                min(credentialDeadline, allowanceEnd ?? requestDeadline)
            )
            guard expiresAt > now else { throw BrokerApprovalError.invalidRequest }
            let entry = Entry(
                trustedCredentialName: trustedCredentialName,
                request: request,
                requestID: UUID().uuidString,
                capability: UUID().uuidString,
                expiresAt: expiresAt,
                credentialExpiresAt: trustedCredentialDeadline.date,
                state: state,
                approvedByTimedAllowance: allowanceEnd != nil,
                retryCount: 0,
                committing: false
            )
            entriesByOperationID[request.operationID] = entry
            operationOrder.append(request.operationID)
            return ticket(for: entry)
        }
    }

    public func status(
        requestID: String,
        capability: String
    ) throws -> BrokerRequestState {
        try status(requestID: requestID, capability: capability, now: clock())
    }

    public func status(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest
    ) throws -> BrokerRequestState {
        try withEntry(requestID: requestID, capability: capability, now: clock()) { entry in
            guard entry.request.matchesForConsumption(operationRequest) else {
                throw BrokerApprovalError.payloadMismatch
            }
            guard entry.state == .pending || entry.state == .approved else {
                throw BrokerApprovalError.invalidDecision
            }
            return entry.state
        }
    }

    /// Test seam. Production callers cannot supply time.
    func status(
        requestID: String,
        capability: String,
        now: Date
    ) throws -> BrokerRequestState {
        try withEntry(requestID: requestID, capability: capability, now: now) { $0.state }
    }

    public func cancel(
        requestID: String,
        capability: String
    ) throws -> BrokerRequestState {
        try cancel(requestID: requestID, capability: capability, now: clock())
    }

    public func cancel(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest
    ) throws -> BrokerRequestState {
        try updateEntry(requestID: requestID, capability: capability, now: clock()) { entry in
            guard entry.request.matchesForConsumption(operationRequest) else {
                throw BrokerApprovalError.payloadMismatch
            }
            if entry.state == .pending || entry.state == .approved { entry.state = .cancelled }
        }.state
    }

    /// Test seam. Production callers cannot supply time.
    func cancel(
        requestID: String,
        capability: String,
        now: Date
    ) throws -> BrokerRequestState {
        try updateEntry(requestID: requestID, capability: capability, now: now) { entry in
            if !entry.committing, entry.state == .pending || entry.state == .approved {
                entry.state = .cancelled
            }
        }.state
    }

    public func pendingRequests() -> [BrokerPendingApproval] {
        mutate {
            expireUnconsumedLocked(now: clock())
            return operationOrder.compactMap { operationID in
                guard let entry = entriesByOperationID[operationID], entry.state == .pending else {
                    return nil
                }
                return BrokerPendingApproval(
                    requestID: entry.requestID,
                    capability: entry.capability,
                    request: entry.request,
                    expiresAt: entry.expiresAt,
                    trustedCredentialName: entry.trustedCredentialName
                )
            }
        }
    }
}
