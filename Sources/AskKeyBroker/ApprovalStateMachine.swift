import Foundation

public enum BrokerApprovalOperation: String, Codable, Equatable, Sendable {
    case read
    case create
    case modify
    case delete
}

/// Vault-derived credential expiry. Agent request fields never supply this value.
public enum BrokerCredentialDeadline: Equatable, Sendable {
    case none
    case expiresAt(Date)
}

public struct BrokerApprovalOperationRequest: Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let payloadDigest: String
    public let retransmissionDigest: String?
    public let credentialName: String?
    public let callerName: String?
    public let callerPurpose: String?

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        payloadDigest: String,
        credentialName: String? = nil,
        callerName: String? = nil,
        callerPurpose: String? = nil,
        retransmissionDigest: String? = nil
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.payloadDigest = payloadDigest
        self.retransmissionDigest = retransmissionDigest
        self.credentialName = credentialName
        self.callerName = callerName
        self.callerPurpose = callerPurpose
    }
}

public struct BrokerApprovalTicket: Codable, Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let state: BrokerRequestState
    public let retryCount: Int

    public init(requestID: String, capability: String, state: BrokerRequestState, retryCount: Int) {
        self.requestID = requestID
        self.capability = capability
        self.state = state
        self.retryCount = retryCount
    }
}

/// App-only projection used to render the direct confirmation surface. It carries
/// request metadata and the opaque decision capability, never credential values.
public struct BrokerPendingApproval: Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let request: BrokerApprovalOperationRequest
    public let expiresAt: Date?
    /// Vault-derived display metadata; never part of the operation binding.
    public let trustedCredentialName: String?

    public var displayCredentialName: String {
        trustedCredentialName ?? request.credentialName ?? request.targetID
    }

    public init(
        requestID: String,
        capability: String,
        request: BrokerApprovalOperationRequest,
        expiresAt: Date? = nil,
        trustedCredentialName: String? = nil
    ) {
        self.requestID = requestID
        self.capability = capability
        self.request = request
        self.expiresAt = expiresAt
        self.trustedCredentialName = trustedCredentialName
    }
}

public struct BrokerApprovalConsumption: Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let operationRequest: BrokerApprovalOperationRequest

    public init(requestID: String, capability: String, operationRequest: BrokerApprovalOperationRequest) {
        self.requestID = requestID
        self.capability = capability
        self.operationRequest = operationRequest
    }
}

/// The original approvals consumed by one runtime operation. Its identity and
/// deadline survive terminal-ticket eviction and cannot be renewed by a later
/// allowance. File cleanup belongs to this identity, never to a credential name.
public final class BrokerRuntimeReadAuthorization: @unchecked Sendable {
    public let expiresAt: Date
    private let owner: BrokerApprovalStateMachine
    private let id: UUID

    fileprivate init(owner: BrokerApprovalStateMachine, id: UUID, expiresAt: Date) {
        self.owner = owner
        self.id = id
        self.expiresAt = expiresAt
    }

    deinit { finish() }

    public func validate() throws {
        try owner.withRuntimeAuthorization(id: id) {}
    }

    /// Call under the Vault spawn gate. Revocation takes the same approval lock
    /// and therefore cannot complete between this check and the actual spawn.
    public func performAuthorizedSpawn<T>(_ spawn: () throws -> T) throws -> T {
        try owner.withRuntimeAuthorization(id: id, spawn)
    }

    /// Registers a specific materialized resource. If invalidation already won,
    /// clean that resource immediately, outside the approval lock, and refuse it.
    public func registerCleanup(_ cleanup: @escaping @Sendable () -> Void) throws {
        try owner.registerRuntimeCleanup(id: id, cleanup: cleanup)
    }

    public func finish() {
        owner.releaseRuntimeAuthorization(id: id)
    }
}

public enum BrokerApprovalDecision: Equatable, Sendable {
    case once
    case deny
    case timedAllow(duration: TimeInterval?)
}

public enum BrokerAuthenticationPurpose: Equatable, Sendable {
    case readApproval
    case writeApproval
}

public struct BrokerPrivacyNotification: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let actions: [String]

    public static let approvalQueueBecameNonempty = BrokerPrivacyNotification(
        title: "Ask Key needs your attention",
        body: "Open Ask Key to review pending requests.",
        actions: []
    )
}

public enum BrokerApprovalError: Error, Equatable {
    case invalidRequest
    case payloadMismatch
    case capacityReached
    case requestNotFound
    case authenticationFailed
    case invalidDecision
    case alreadyConsumed
    case commitInProgress
    case agentAccessPaused
}

/// Owns operation idempotency and approval state for the App's single Broker.
/// Mutable state is protected by `lock`; callers never receive credential data.
public final class BrokerApprovalStateMachine: @unchecked Sendable {
    private struct RuntimeAuthorization {
        let credentialIDs: Set<String>
        let expiresAt: Date
        var valid = true
        var cleanups: [@Sendable () -> Void] = []
    }

    private struct Entry {
        let trustedCredentialName: String?
        let request: BrokerApprovalOperationRequest
        let requestID: String
        let capability: String
        var expiresAt: Date
        let credentialExpiresAt: Date?
        var state: BrokerRequestState
        var approvedByTimedAllowance: Bool
        var retryCount: Int
        var committing: Bool
    }

    private let lock = NSLock()
    private let observerLock = NSRecursiveLock()
    private let observerQueue = DispatchQueue(label: "com.sudohg.askkey.approval-observers")
    private let expirationTimer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "com.sudohg.askkey.approval-expiration")
    )
    private var authenticate: @Sendable (BrokerAuthenticationPurpose) -> Bool
    private let clock: @Sendable () -> Date
    private var notify: @Sendable (BrokerPrivacyNotification) -> Void
    private var pendingCountChanged: @Sendable (Int) -> Void
    private var timedAllowanceRevoked: @Sendable (String) -> Void
    private var operationStateChanged: @Sendable (
        String, BrokerApprovalOperationRequest?, BrokerRequestState
    ) -> Void = { _, _, _ in }
    private let requestTTL: TimeInterval
    private var defaultTimedAllowance: TimeInterval
    private var readAuthenticationEnabled: Bool
    private var entriesByOperationID: [String: Entry] = [:]
    private var operationOrder: [String] = []
    private var timedAllowances: [String: Date] = [:]
    // Active leases are independent of the bounded, evictable ticket history.
    private var runtimeAuthorizations: [UUID: RuntimeAuthorization] = [:]
    private var reportedPendingCount = 0
    private var stateRevision: UInt64 = 0
    private var reportedRevision: UInt64 = 0
    private var hasScheduledExpiration = false
    private var paused = false

    public init(
        requestTTL: TimeInterval = 5 * 60,
        defaultTimedAllowance: TimeInterval = 30 * 60,
        readAuthenticationEnabled: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() },
        authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool = { _ in false },
        notify: @escaping @Sendable (BrokerPrivacyNotification) -> Void = { _ in },
        pendingCountChanged: @escaping @Sendable (Int) -> Void = { _ in },
        timedAllowanceRevoked: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.requestTTL = Self.validDuration(requestTTL) ? requestTTL : 5 * 60
        self.defaultTimedAllowance = Self.validDuration(defaultTimedAllowance)
            ? defaultTimedAllowance
            : 30 * 60
        self.readAuthenticationEnabled = readAuthenticationEnabled
        self.clock = clock
        self.authenticate = authenticate
        self.notify = notify
        self.pendingCountChanged = pendingCountChanged
        self.timedAllowanceRevoked = timedAllowanceRevoked
        expirationTimer.setEventHandler { [weak self] in self?.expireScheduledRequests() }
        expirationTimer.schedule(deadline: .distantFuture)
        expirationTimer.resume()
    }

    public func updateDefaultTimedAllowance(_ duration: TimeInterval) {
        mutate {
            defaultTimedAllowance = Self.validDuration(duration) ? duration : 30 * 60
        }
    }

    deinit {
        expirationTimer.setEventHandler {}
        expirationTimer.cancel()
    }

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

    public func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        try decide(requestID: requestID, capability: capability, decision: decision, now: clock())
    }

    /// Test seam. Production callers cannot supply time.
    func decide(
        requestID: String,
        capability: String,
        decision: BrokerApprovalDecision,
        now: Date
    ) throws -> BrokerApprovalTicket {
        let context = try withEntry(requestID: requestID, capability: capability, now: now) {
            ($0, readAuthenticationEnabled)
        }
        let entry = context.0
        guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
        if case let .timedAllow(duration) = decision {
            guard entry.request.operation == .read else { throw BrokerApprovalError.invalidDecision }
            if let duration, !Self.validDuration(duration) { throw BrokerApprovalError.invalidDecision }
        }
        if decision != .deny,
           entry.request.operation != .read || context.1 {
            let purpose: BrokerAuthenticationPurpose = entry.request.operation == .read
                ? .readApproval
                : .writeApproval
            observerLock.lock()
            let authenticate = self.authenticate
            observerLock.unlock()
            guard authenticate(purpose) else { throw BrokerApprovalError.authenticationFailed }
        }
        let verifiedAt = decision == .deny ? now : max(now, clock())

        return try updateEntry(requestID: requestID, capability: capability, now: verifiedAt) { entry in
            guard entry.state == .pending else { throw BrokerApprovalError.invalidDecision }
            switch decision {
            case .deny:
                entry.state = .denied
            case .once:
                entry.state = .approved
                entry.approvedByTimedAllowance = false
            case let .timedAllow(duration):
                let windowEnd = verifiedAt.addingTimeInterval(duration ?? defaultTimedAllowance)
                let effectiveWindowEnd = entry.credentialExpiresAt.map {
                    min(windowEnd, $0)
                } ?? windowEnd
                timedAllowances[entry.request.credentialID] = effectiveWindowEnd
                entry.expiresAt = min(entry.expiresAt, effectiveWindowEnd)
                entry.state = .approved
                entry.approvedByTimedAllowance = true
            }
        }
    }

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

    fileprivate func withRuntimeAuthorization<T>(id: UUID, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let authorization = runtimeAuthorizations[id], authorization.valid,
              !paused, clock() < authorization.expiresAt else {
            throw BrokerProviderError.requestRejected
        }
        // No observer, file IO, or acquisition of the Vault gate while locked.
        return try body()
    }

    fileprivate func registerRuntimeCleanup(id: UUID, cleanup: @escaping @Sendable () -> Void) throws {
        lock.lock()
        if var authorization = runtimeAuthorizations[id], authorization.valid,
           !paused, clock() < authorization.expiresAt {
            authorization.cleanups.append(cleanup)
            runtimeAuthorizations[id] = authorization
            lock.unlock()
        } else {
            lock.unlock()
            cleanup()
            throw BrokerProviderError.requestRejected
        }
    }

    fileprivate func releaseRuntimeAuthorization(id: UUID) {
        let cleanups = mutate { runtimeAuthorizations.removeValue(forKey: id)?.cleanups ?? [] }
        cleanups.forEach { $0() }
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

    public func setReadAuthenticationEnabled(_ enabled: Bool) {
        mutate { readAuthenticationEnabled = enabled }
    }

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

    public func configureObservers(
        notify: @escaping @Sendable (BrokerPrivacyNotification) -> Void,
        pendingCountChanged: @escaping @Sendable (Int) -> Void
    ) {
        observerLock.lock()
        self.notify = notify
        self.pendingCountChanged = pendingCountChanged
        reportedPendingCount = 0
        reportedRevision = 0
        observerLock.unlock()
        lock.lock()
        let publication = pendingPublicationLocked()
        lock.unlock()
        publishPendingCount(publication)
    }

    public func configureAuthentication(
        _ authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool
    ) {
        observerLock.lock()
        self.authenticate = authenticate
        observerLock.unlock()
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

    public func configureOperationStateChanged(
        _ operationStateChanged: @escaping @Sendable (
            String, BrokerApprovalOperationRequest?, BrokerRequestState
        ) -> Void
    ) {
        observerLock.lock()
        self.operationStateChanged = operationStateChanged
        observerLock.unlock()
    }

    /// Test seam for deterministic assertions over asynchronously delivered observers.
    func flushObservers() {
        observerQueue.sync {}
    }

    /// Test seam: the state machine owns at most one reschedulable expiration task.
    var scheduledExpirationTaskCount: Int {
        lock.lock(); defer { lock.unlock() }
        return hasScheduledExpiration ? 1 : 0
    }

    private func withEntry<T>(
        requestID: String,
        capability: String,
        now: Date,
        body: (Entry) throws -> T
    ) throws -> T {
        try mutate {
            expireUnconsumedLocked(now: now)
            guard let entry = matchingEntry(requestID: requestID, capability: capability) else {
                throw BrokerApprovalError.requestNotFound
            }
            return try body(entry)
        }
    }

    private func updateEntry(
        requestID: String,
        capability: String,
        now: Date,
        body: (inout Entry) throws -> Void
    ) throws -> BrokerApprovalTicket {
        try mutate {
            expireUnconsumedLocked(now: now)
            guard let operationID = entriesByOperationID.first(where: {
                $0.value.requestID == requestID && $0.value.capability == capability
            })?.key, var entry = entriesByOperationID[operationID] else {
                throw BrokerApprovalError.requestNotFound
            }
            try body(&entry)
            entriesByOperationID[operationID] = entry
            return ticket(for: entry)
        }
    }

    private func expireUnconsumedLocked(now: Date) {
        for operationID in entriesByOperationID.keys {
            guard var entry = entriesByOperationID[operationID],
                  entry.state == .pending || entry.state == .approved,
                  !entry.committing,
                  now >= entry.expiresAt else { continue }
            entry.state = .expired
            entriesByOperationID[operationID] = entry
        }
    }

    private func expireTimedAllowancesLocked(now: Date) {
        timedAllowances = timedAllowances.filter { $0.value > now }
    }

    private func invalidateRuntimeAuthorizationsLocked(credentialID: String? = nil) {
        for id in runtimeAuthorizations.keys {
            guard var authorization = runtimeAuthorizations[id],
                  credentialID == nil || authorization.credentialIDs.contains(credentialID!) else { continue }
            authorization.valid = false
            runtimeAuthorizations[id] = authorization
        }
    }

    private func runtimeInvalidationCleanupsLocked(now: Date) -> [@Sendable () -> Void] {
        var cleanups: [@Sendable () -> Void] = []
        for id in runtimeAuthorizations.keys {
            guard var authorization = runtimeAuthorizations[id],
                  !authorization.valid || now >= authorization.expiresAt else { continue }
            authorization.valid = false
            cleanups.append(contentsOf: authorization.cleanups)
            authorization.cleanups.removeAll()
            runtimeAuthorizations[id] = authorization
        }
        return cleanups
    }

    private func expireScheduledRequests() {
        let now = clock()
        mutate {
            expireUnconsumedLocked(now: now)
            expireTimedAllowancesLocked(now: now)
        }
    }

    private static func validDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0
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

    private static func valid(_ request: BrokerApprovalOperationRequest) -> Bool {
        let required = [
            request.operationID,
            request.credentialID,
            request.targetID,
            request.payloadDigest,
        ]
        return required.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= BrokerLimits.maximumFieldBytes
        } && [request.credentialName, request.callerName, request.callerPurpose]
            .compactMap { $0 }
            .allSatisfy { $0.utf8.count <= BrokerLimits.maximumFieldBytes }
            && (request.operation == .create || request.targetID == request.credentialID)
            && [request.retransmissionDigest].compactMap { $0 }.allSatisfy {
                $0.utf8.count == 64 && $0.unicodeScalars.allSatisfy {
                    CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
                }
            }
            && request.payloadDigest.utf8.count == 64
            && request.payloadDigest.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
            }
    }

    private func makeRetentionRoom() throws {
        guard entriesByOperationID.count >= BrokerLimits.maximumRetainedRequestStates else { return }
        guard let index = operationOrder.firstIndex(where: {
            guard let state = entriesByOperationID[$0]?.state else { return false }
            return state != .pending && state != .approved
        }) else {
            throw BrokerApprovalError.capacityReached
        }
        entriesByOperationID.removeValue(forKey: operationOrder.remove(at: index))
    }

    private func mutate<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        let schedulingNow = clock()
        let previousEntries = entriesByOperationID.mapValues { ($0.state, $0.request) }
        do {
            let result = try body()
            stateRevision &+= 1
            let publication = pendingPublicationLocked()
            let terminalTransitions = terminalTransitionsLocked(from: previousEntries)
            let cleanups = runtimeInvalidationCleanupsLocked(now: schedulingNow)
            rescheduleExpirationLocked(now: schedulingNow)
            lock.unlock()
            cleanups.forEach { $0() }
            publishPendingCount(publication)
            publishTerminalTransitions(terminalTransitions)
            return result
        } catch {
            stateRevision &+= 1
            let publication = pendingPublicationLocked()
            let terminalTransitions = terminalTransitionsLocked(from: previousEntries)
            let cleanups = runtimeInvalidationCleanupsLocked(now: schedulingNow)
            rescheduleExpirationLocked(now: schedulingNow)
            lock.unlock()
            cleanups.forEach { $0() }
            publishPendingCount(publication)
            publishTerminalTransitions(terminalTransitions)
            throw error
        }
    }

    private func terminalTransitionsLocked(
        from previousEntries: [String: (BrokerRequestState, BrokerApprovalOperationRequest)]
    ) -> [(String, BrokerApprovalOperationRequest?, BrokerRequestState)] {
        previousEntries.compactMap { operationID, previous in
            guard previous.0 == .pending || previous.0 == .approved else { return nil }
            guard let state = entriesByOperationID[operationID]?.state else {
                // Retention can evict an entry after this mutation expires it.
                return (operationID, previous.1, .expired)
            }
            guard state != .pending, state != .approved else { return nil }
            return (operationID, entriesByOperationID[operationID]?.request, state)
        }
    }

    private func publishTerminalTransitions(
        _ transitions: [(String, BrokerApprovalOperationRequest?, BrokerRequestState)]
    ) {
        guard !transitions.isEmpty else { return }
        observerLock.lock()
        let operationStateChanged = self.operationStateChanged
        observerLock.unlock()
        for (operationID, request, state) in transitions {
            operationStateChanged(operationID, request, state)
        }
    }

    private func pendingPublicationLocked() -> (revision: UInt64, count: Int) {
        let count = entriesByOperationID.values.reduce(into: 0) {
            if $1.state == .pending { $0 += 1 }
        }
        return (stateRevision, count)
    }

    private func rescheduleExpirationLocked(now: Date) {
        let requestExpirations = entriesByOperationID.values
            .filter { !$0.committing && ($0.state == .pending || $0.state == .approved) }
            .map(\.expiresAt)
        let runtimeExpirations = runtimeAuthorizations.values.filter(\.valid).map(\.expiresAt)
        let nextExpiration = (requestExpirations + runtimeExpirations + Array(timedAllowances.values)).min()
        guard let nextExpiration else {
            hasScheduledExpiration = false
            expirationTimer.schedule(deadline: .distantFuture)
            return
        }
        hasScheduledExpiration = true
        let delay = max(0, nextExpiration.timeIntervalSince(now))
        expirationTimer.schedule(
            deadline: .now() + delay,
            repeating: .never,
            leeway: .milliseconds(10)
        )
    }

    private func publishPendingCount(_ publication: (revision: UInt64, count: Int)) {
        observerQueue.async { [weak self] in
            self?.deliverPendingCount(publication)
        }
    }

    private func deliverPendingCount(_ publication: (revision: UInt64, count: Int)) {
        observerLock.lock()
        guard publication.revision > reportedRevision else {
            observerLock.unlock()
            return
        }
        reportedRevision = publication.revision
        let shouldNotify = reportedPendingCount == 0 && publication.count > 0
        let countChanged = reportedPendingCount != publication.count
        reportedPendingCount = publication.count
        let notify = self.notify
        let pendingCountChanged = self.pendingCountChanged
        observerLock.unlock()
        if countChanged { pendingCountChanged(publication.count) }
        if shouldNotify {
            notify(.approvalQueueBecameNonempty)
        }
    }

    private func matchingEntry(requestID: String, capability: String) -> Entry? {
        // ponytail: bounded O(n) lookup (max 256); add an index only if the cap grows.
        entriesByOperationID.values.first {
            $0.requestID == requestID && $0.capability == capability
        }
    }

    private func ticket(for entry: Entry) -> BrokerApprovalTicket {
        .init(
            requestID: entry.requestID,
            capability: entry.capability,
            state: entry.state,
            retryCount: entry.retryCount
        )
    }
}

private extension BrokerApprovalOperationRequest {
    func matchesForConsumption(_ other: BrokerApprovalOperationRequest) -> Bool {
        operationID == other.operationID
            && credentialID == other.credentialID
            && targetID == other.targetID
            && operation == other.operation
            && credentialName == other.credentialName
            && callerName == other.callerName
            && callerPurpose == other.callerPurpose
            && retransmissionDigest == other.retransmissionDigest
            && constantTimeEqual(payloadDigest, other.payloadDigest)
    }

    func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension BrokerCredentialDeadline {
    var date: Date? {
        switch self {
        case .none: return nil
        case .expiresAt(let date): return date
        }
    }
}
