import AskKeyDevices
import Foundation

extension AppModel {
    /// The most delivery records kept.
    static let deliveryRecordLimit = 50
    /// How long the app looks for the message a push pointed to.
    static let pushHintLifetime = MessageKind.deliveryCheckLifetime + 5 * 60
    /// The most pushes kept while the app launches.
    static let earlyPushLimit = 20
    /// The most push hints kept.
    static let pushHintLimit = 100
    /// How long a reset waits for CloudKit to delete the inbox.
    static let inboxRemovalTimeout: TimeInterval = 10

    /// The app became active: collect the pushes still in Notification
    /// Center, then process the inbox.
    public func becameActive() async {
        guard stage == .ready, let services else { return }
        remember(await environment.notifications.deliveredPushHints(for: services.deviceID))
        await processInbox()
    }

    /// A push arrived while the app runs, or the person opened one
    /// (`opened`). It is only a hint: the app fetches its inbox and acts on
    /// what it verifies, never on the notification's text, category or
    /// action. Opening one opens its request's card when the app holds or,
    /// within a minute, verifies that request.
    public func receivedPush(userInfo: [AnyHashable: Any], arrivedAt: Date, notificationIdentifier: String?,
                             opened: Bool = false) async {
        guard let services else {
            // Opening a notification launched the app, and the identity is
            // not restored yet: keep the push until it is.
            if stage == .starting, earlyPushes.count < Self.earlyPushLimit {
                earlyPushes.append(EarlyPush(userInfo: userInfo, arrivedAt: arrivedAt, identifier: notificationIdentifier,
                                             opened: opened))
            }
            return
        }
        guard let hint = PushHintReader.hint(userInfo: userInfo, arrivedAt: arrivedAt,
                                             notificationIdentifier: notificationIdentifier,
                                             for: services.deviceID) else { return }
        remember([hint])
        if opened {
            open(hint.recordName)
            rebuildRequests()
        }
        await processInbox()
    }

    /// Turns the pushes kept during launch into hints for this device.
    func adoptEarlyPushes(for device: DeviceID) {
        let pushes = earlyPushes
        earlyPushes = []
        for push in pushes {
            guard let hint = PushHintReader.hint(userInfo: push.userInfo, arrivedAt: push.arrivedAt,
                                                 notificationIdentifier: push.identifier, for: device) else { continue }
            remember([hint])
            if push.opened { open(hint.recordName) }
        }
    }

    private func open(_ recordName: String) {
        pendingOpen = recordName
        pendingOpenSince = environment.clock.now()
    }

    /// Keeps each record's first hint and every delivered notification for
    /// it. A notification for a request already settled here is removed at
    /// once; hints older than their lifetime go with their notifications.
    func remember(_ hints: [PushHint]) {
        let now = environment.clock.now()
        var stale: [String] = []
        for hint in hints {
            let name = hint.recordName
            if settledRequests.contains(name) {
                if let identifier = hint.notificationIdentifier { stale.append(identifier) }
                continue
            }
            guard let known = pushHints[name] else {
                pushHints[name] = hint
                continue
            }
            guard let identifier = hint.notificationIdentifier, identifier != known.notificationIdentifier else { continue }
            if known.notificationIdentifier == nil {
                pushHints[name] = PushHint(recordName: name, arrivedAt: known.arrivedAt, notificationIdentifier: identifier)
            } else {
                extraNotifications[name, default: []].insert(identifier)
            }
        }
        for (name, hint) in pushHints where now.timeIntervalSince(hint.arrivedAt) > Self.pushHintLifetime {
            pushHints[name] = nil
            if let identifier = hint.notificationIdentifier { stale.append(identifier) }
            stale += extraNotifications.removeValue(forKey: name) ?? []
        }
        // A flood of pushes keeps only the newest hints.
        if pushHints.count > Self.pushHintLimit {
            let oldest = pushHints.values.sorted { $0.arrivedAt < $1.arrivedAt }.prefix(pushHints.count - Self.pushHintLimit)
            for hint in oldest {
                pushHints[hint.recordName] = nil
                if let identifier = hint.notificationIdentifier { stale.append(identifier) }
                stale += extraNotifications.removeValue(forKey: hint.recordName) ?? []
            }
        }
        namedFetched.formIntersection(pushHints.keys)
        environment.notifications.removeDeliveredNotifications(identifiers: stale)
    }

    /// Fetches and processes the inbox: challenges, confirmations,
    /// cancellations, delivery checks (answered at once with the message key,
    /// without a prompt), unpair notices, approval requests and closed
    /// messages; then fetches by name the records pushes named that the
    /// zone poll did not settle, and sends what is due. Calls made while a
    /// fetch runs wait for it and fetch once more afterwards.
    public func processInbox() async {
        if let running = inboxWork {
            pollAgain = true
            await running.value
            return
        }
        let work = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.pollAgain = false
                await self.pollOnce()
            } while self.pollAgain && self.stage == .ready
            // Cleared in the same step as the last check, so no call is lost.
            self.inboxWork = nil
        }
        inboxWork = work
        await work.value
    }

    private func pollOnce() async {
        guard stage == .ready, let services else { return }
        if !accountChecked || accountNotice != nil { await refreshAccount() }
        guard accountNotice == nil, self.services === services else { return }
        let before = try? await services.registry.list()
        var outcomes: [String: InboxMessageOutcome] = [:]
        do {
            // The zone poll goes first: within one fetch a closed message is
            // handled before its request, so it keeps the request hidden.
            let report = try await services.messenger.poll()
            guard self.services === services else { return }
            if let token = await services.messenger.inboxToken, var position = environment.localState.inboxPosition {
                position.token = token.data
                environment.localState.inboxPosition = position
            }
            outcomes = report.outcomes
            AppLog.refusals(report.refusals)
        } catch is DeviceIdentityError {
            guard self.services === services else { return }
            identityBecameUnusable()
            return
        } catch {
            AppLog.failure("Fetching the inbox", error)
        }
        guard self.services === services else { return }
        guard await fetchPushedRecords(services, skipping: outcomes, into: &outcomes) else { return }
        recordDeliveries(outcomes, kinds: services.transport.takeKinds())
        await refreshList(previous: before)
        // Sends and local expiry go on even when the inbox could not be read.
        await serviceApprovals()
    }

    /// Fetches by name, once each, the records pushes named that the zone
    /// poll did not report, waiting as long as CloudKit asked. Returns false
    /// when this iPhone's own key failed.
    private func fetchPushedRecords(_ services: DeviceServices, skipping polled: [String: InboxMessageOutcome],
                                    into outcomes: inout [String: InboxMessageOutcome]) async -> Bool {
        let now = environment.clock.now()
        if let notBefore = namedFetchNotBefore, now < notBefore { return true }
        let names = Array(pushHints.keys.filter { !namedFetched.contains($0) && polled[$0] == nil }.sorted().prefix(100))
        guard !names.isEmpty else { return true }
        namedFetched.formUnion(names)
        do {
            let report = try await services.messenger.fetchNamedMessages(names)
            outcomes.merge(report.outcomes) { polled, _ in polled }
            namedFetchNotBefore = report.retryAfter.map { environment.clock.now().addingTimeInterval($0) }
        } catch is DeviceIdentityError {
            guard self.services === services else { return false }
            identityBecameUnusable()
            return false
        } catch {
            if let transportError = error as? DeviceTransportError, case .rateLimited(let retryAfter?) = transportError {
                namedFetchNotBefore = environment.clock.now().addingTimeInterval(retryAfter)
            }
            AppLog.failure("Fetching pushed messages", error)
        }
        return self.services === services
    }

    /// Records each answered delivery check, found through a push when one
    /// pointed to its record and by polling otherwise, and clears the
    /// notifications of messages that are settled. A request still waiting
    /// for a decision keeps its notification until it settles.
    func recordDeliveries(_ outcomes: [String: InboxMessageOutcome], kinds: [String: Int64]) {
        let now = environment.clock.now()
        var settled: [String] = []
        for name in outcomes.keys.sorted() {
            switch outcomes[name] {
            case .processed?:
                if kinds[name] == Int64(MessageKind.deliveryCheck.rawValue) {
                    let hint = pushHints[name]
                    append(DeliveryRecord(recordName: name, arrivedAt: hint?.arrivedAt ?? now,
                                          source: hint == nil ? .polling : .push))
                }
                if isPendingRequest(name) { continue }
            case .refused?:
                break
            default:
                continue
            }
            settled.append(name)
        }
        removeNotifications(of: settled)
    }

    private func append(_ record: DeliveryRecord) {
        AppLog.delivery(record)
        deliveryRecords = Array((deliveryRecords + [record]).suffix(Self.deliveryRecordLimit))
        environment.localState.deliveryRecords = deliveryRecords
    }

    // MARK: Reset

    /// Deletes the keys and the paired-device list after stopping the device
    /// services, deletes this device's inbox and subscriptions when CloudKit
    /// answers in time, and returns to the welcome screen.
    public func resetIdentity() async {
        guard stage == .unusableIdentity, !isResetting else { return }
        isResetting = true
        resetFailed = false
        defer { isResetting = false }
        pairing = nil
        let services = self.services
        self.services = nil
        await inboxWork?.value
        let transport: (any InboxTransport)? = services?.transport
            ?? environment.localState.deviceID.flatMap(DeviceID.init(text:)).flatMap(environment.cloud.makeTransport(for:))
        do {
            try keychain.deleteEverything()
        } catch {
            AppLog.failure("Deleting the keys", error)
            resetFailed = true
            return
        }
        environment.localState.removeAll()
        do {
            try environment.approvals.removeApprovals()
        } catch {
            AppLog.failure("Deleting the stored requests", error)
        }
        dropAllApprovals()
        revokedPairings = []
        deliveryRecords = []
        pairedMacs = []
        pushHints = [:]
        namedFetched = []
        namedFetchNotBefore = nil
        extraNotifications = [:]
        settledRequests = []
        knownList = nil
        seenPairings = nil
        locallyRemoved = []
        listNotice = nil
        accountNotice = nil
        accountChecked = false
        pendingSetup = nil
        if let transport {
            await Self.waitAtMost(Self.inboxRemovalTimeout) {
                do {
                    try await transport.removeInbox()
                } catch {
                    AppLog.failure("Deleting the inbox", error)
                }
            }
        }
        welcomeStep = .intro
        stage = .welcome
    }

    /// Waits for `operation`, but no longer than `seconds`; the operation
    /// keeps running in the background after that.
    static func waitAtMost(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async {
        let gate = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await operation()
                if gate.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() { continuation.resume() }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
