import Foundation

extension BrokerApprovalStateMachine {
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

    func mutate<T>(_ body: () throws -> T) rethrows -> T {
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
}
