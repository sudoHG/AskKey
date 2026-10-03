import Foundation

/// Owns operation idempotency and approval state for the App's single Broker.
/// Mutable state is protected by `lock`; callers never receive credential data.
public final class BrokerApprovalStateMachine: @unchecked Sendable {
    struct RuntimeAuthorization {
        let credentialIDs: Set<String>
        let expiresAt: Date
        var valid = true
        var cleanups: [@Sendable () -> Void] = []
    }

    struct Entry {
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

    let lock = NSLock()
    let observerLock = NSRecursiveLock()
    let observerQueue = DispatchQueue(label: "com.sudohg.askkey.approval-observers")
    let expirationTimer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "com.sudohg.askkey.approval-expiration")
    )
    var authenticate: @Sendable (BrokerAuthenticationPurpose) -> Bool
    let clock: @Sendable () -> Date
    var notify: @Sendable (BrokerPrivacyNotification) -> Void
    var pendingCountChanged: @Sendable (Int) -> Void
    var timedAllowanceRevoked: @Sendable (String) -> Void
    var operationStateChanged: @Sendable (
        String, BrokerApprovalOperationRequest?, BrokerRequestState
    ) -> Void = { _, _, _ in }
    let requestTTL: TimeInterval
    var defaultTimedAllowance: TimeInterval
    var readAuthenticationEnabled: Bool
    var entriesByOperationID: [String: Entry] = [:]
    var operationOrder: [String] = []
    var timedAllowances: [String: Date] = [:]
    // Active leases are independent of the bounded, evictable ticket history.
    var runtimeAuthorizations: [UUID: RuntimeAuthorization] = [:]
    var reportedPendingCount = 0
    var stateRevision: UInt64 = 0
    var reportedRevision: UInt64 = 0
    var hasScheduledExpiration = false
    var paused = false

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

    deinit {
        expirationTimer.setEventHandler {}
        expirationTimer.cancel()
    }

}
