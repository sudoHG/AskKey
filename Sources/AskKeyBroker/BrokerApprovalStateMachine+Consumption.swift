import Foundation

extension BrokerApprovalStateMachine {
    public func consume(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest
    ) throws -> BrokerRequestState {
        try consumeApproved(
            requestID: requestID,
            capability: capability,
            operationRequest: operationRequest,
            perform: { BrokerRequestState.consumed }
        )
    }

    /// Runs the approved operation while the approval is exclusively held and
    /// marks it consumed only after the operation succeeds. This lets a storage
    /// transaction fail without burning the one-time approval.
    public func consumeApproved<T>(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        perform: () throws -> T
    ) throws -> T {
        try reserveConsumption(
            requestID: requestID,
            capability: capability,
            operationRequest: operationRequest
        )
        do {
            let result = try perform()
            _ = try finishConsumption(
                requestID: requestID,
                capability: capability,
                consumed: true
            )
            return result
        } catch let operationError {
            do {
                _ = try finishConsumption(
                    requestID: requestID,
                    capability: capability,
                    consumed: false
                )
            } catch {
                throw error
            }
            throw operationError
        }
    }

    /// Reserves one approved operation, runs the idempotent business write without
    /// the state lock, then consumes it. A thrown write releases the reservation.
    public func consume(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        performing operation: () throws -> Void
    ) throws -> BrokerRequestState {
        try reserveConsumption(
            requestID: requestID,
            capability: capability,
            operationRequest: operationRequest
        )
        do {
            try operation()
        } catch let operationError {
            do {
                _ = try finishConsumption(
                    requestID: requestID,
                    capability: capability,
                    consumed: false
                )
            } catch {
                throw error
            }
            throw operationError
        }
        return try finishConsumption(
            requestID: requestID,
            capability: capability,
            consumed: true
        ).state
    }

    /// Atomically validates and consumes a complete runtime credential set.
    public func consume(_ consumptions: [BrokerApprovalConsumption]) throws {
        _ = try mutate { try consumeBatchLocked(consumptions) }
    }

    /// Runtime-only consumption. Existing write reservation/commit APIs retain
    /// their transaction and retry semantics and never hold this lock over SQL.
    public func consumeForRuntime(
        _ consumptions: [BrokerApprovalConsumption]
    ) throws -> BrokerRuntimeReadAuthorization? {
        let snapshot: (UUID, Date)? = try mutate {
            guard !paused, consumptions.allSatisfy({ $0.operationRequest.operation == .read }) else {
                throw BrokerApprovalError.invalidDecision
            }
            let entries = try consumeBatchLocked(consumptions)
            guard let expiresAt = entries.map(\.expiresAt).min() else { return nil }
            let id = UUID()
            runtimeAuthorizations[id] = RuntimeAuthorization(
                credentialIDs: Set(entries.map { $0.request.credentialID }),
                expiresAt: expiresAt
            )
            return (id, expiresAt)
        }
        return snapshot.map { BrokerRuntimeReadAuthorization(owner: self, id: $0.0, expiresAt: $0.1) }
    }

    private func consumeBatchLocked(_ consumptions: [BrokerApprovalConsumption]) throws -> [Entry] {
        expireUnconsumedLocked(now: clock())
        var entries: [Entry] = []
        for consumption in consumptions {
            guard let entry = matchingEntry(requestID: consumption.requestID, capability: consumption.capability) else {
                throw BrokerApprovalError.requestNotFound
            }
            guard entry.request.matchesForConsumption(consumption.operationRequest) else {
                throw BrokerApprovalError.payloadMismatch
            }
            if entry.state == .consumed { throw BrokerApprovalError.alreadyConsumed }
            if entry.committing { throw BrokerApprovalError.commitInProgress }
            guard entry.state == .approved else { throw BrokerApprovalError.invalidDecision }
            entries.append(entry)
        }
        for var entry in entries {
            entry.state = .consumed
            entriesByOperationID[entry.request.operationID] = entry
        }
        return entries
    }


    /// Test seam. Production callers cannot supply time.
    func consume(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        now: Date
    ) throws -> BrokerRequestState {
        try consumeApproved(
            requestID: requestID,
            capability: capability,
            operationRequest: operationRequest,
            now: now
        ) { BrokerRequestState.consumed }
    }

    private func consumeApproved<T>(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        now: Date,
        perform: () throws -> T
    ) throws -> T {
        try mutate {
            expireUnconsumedLocked(now: now)
            guard let operationID = entriesByOperationID.first(where: {
                $0.value.requestID == requestID && $0.value.capability == capability
            })?.key, var entry = entriesByOperationID[operationID] else {
                throw BrokerApprovalError.requestNotFound
            }
            guard entry.request.matchesForConsumption(operationRequest) else {
                throw BrokerApprovalError.payloadMismatch
            }
            if entry.state == .consumed { throw BrokerApprovalError.alreadyConsumed }
            if entry.committing { throw BrokerApprovalError.commitInProgress }
            guard entry.state == .approved else { throw BrokerApprovalError.invalidDecision }
            let result = try perform()
            entry.state = .consumed
            entriesByOperationID[operationID] = entry
            return result
        }
    }

    private func reserveConsumption(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest
    ) throws {
        _ = try updateEntry(
            requestID: requestID,
            capability: capability,
            now: clock()
        ) { entry in
            guard !paused else { throw BrokerApprovalError.agentAccessPaused }
            guard entry.request.matchesForConsumption(operationRequest) else {
                throw BrokerApprovalError.payloadMismatch
            }
            if entry.state == .consumed { throw BrokerApprovalError.alreadyConsumed }
            guard entry.state == .approved else { throw BrokerApprovalError.invalidDecision }
            guard !entry.committing else { throw BrokerApprovalError.commitInProgress }
            entry.committing = true
        }
    }

    private func finishConsumption(
        requestID: String,
        capability: String,
        consumed: Bool
    ) throws -> BrokerApprovalTicket {
        try updateEntry(
            requestID: requestID,
            capability: capability,
            now: clock()
        ) { entry in
            guard entry.committing else { throw BrokerApprovalError.invalidDecision }
            entry.committing = false
            if consumed {
                entry.state = .consumed
            } else if paused {
                entry.state = .cancelled
            }
        }
    }
}
