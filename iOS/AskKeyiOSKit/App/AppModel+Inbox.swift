import AskKeyDevices
import Foundation

extension AppModel {
    /// The most delivery records kept.
    static let deliveryRecordLimit = 50
    /// How long the app looks for the message a push pointed to.
    static let pushHintLifetime = MessageKind.deliveryCheckLifetime + 5 * 60
    /// How long a reset waits for CloudKit to delete the inbox.
    static let inboxRemovalTimeout: TimeInterval = 10

    /// The app became active: collect the pushes still in Notification
    /// Center, then process the inbox.
    public func becameActive() async {
        guard stage == .ready, let services else { return }
        remember(await environment.notifications.deliveredPushHints(for: services.deviceID))
        await processInbox()
    }

    /// A push arrived while the app runs, or the person opened one. It is
    /// only a hint: the app fetches its inbox and acts on what it verifies,
    /// never on the notification's text, category or action.
    public func receivedPush(userInfo: [AnyHashable: Any], arrivedAt: Date, notificationIdentifier: String?) async {
        guard let services else { return }
        guard let hint = PushHintReader.hint(userInfo: userInfo, arrivedAt: arrivedAt,
                                             notificationIdentifier: notificationIdentifier,
                                             for: services.deviceID) else { return }
        remember([hint])
        await processInbox()
    }

    func remember(_ hints: [PushHint]) {
        let now = environment.clock.now()
        var stale: [String] = []
        for hint in hints where pushHints[hint.recordName] == nil {
            pushHints[hint.recordName] = hint
        }
        for (name, hint) in pushHints where now.timeIntervalSince(hint.arrivedAt) > Self.pushHintLifetime {
            pushHints[name] = nil
            if let identifier = hint.notificationIdentifier { stale.append(identifier) }
        }
        environment.notifications.removeDeliveredNotifications(identifiers: stale)
    }

    /// Fetches and processes the inbox: challenges, confirmations,
    /// cancellations, delivery checks (answered at once with the message key,
    /// without a prompt) and unpair notices. Calls made while a fetch runs
    /// wait for it and fetch once more afterwards.
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
        }
        inboxWork = work
        await work.value
        inboxWork = nil
    }

    private func pollOnce() async {
        guard stage == .ready, let services else { return }
        if !accountChecked || accountNotice != nil { await refreshAccount() }
        guard accountNotice == nil, self.services === services else { return }
        let before = try? await services.registry.list()
        let report: InboxReport
        do {
            report = try await services.messenger.poll()
        } catch is DeviceIdentityError {
            guard self.services === services else { return }
            identityBecameUnusable()
            return
        } catch {
            AppLog.failure("Fetching the inbox", error)
            return
        }
        guard self.services === services else { return }
        if let token = await services.messenger.inboxToken, var position = environment.localState.inboxPosition {
            position.token = token.data
            environment.localState.inboxPosition = position
        }
        recordDeliveries(report, kinds: services.transport.takeKinds())
        AppLog.refusals(report.refusals)
        await refreshList(previous: before)
    }

    /// Records each answered delivery check, found through a push when one
    /// pointed to its record and by polling otherwise, and clears the
    /// notifications of messages that are settled.
    func recordDeliveries(_ report: InboxReport, kinds: [String: Int64]) {
        let now = environment.clock.now()
        var settled: [String] = []
        for name in report.outcomes.keys.sorted() {
            switch report.outcomes[name] {
            case .processed?:
                if kinds[name] == Int64(MessageKind.deliveryCheck.rawValue) {
                    let hint = pushHints[name]
                    append(DeliveryRecord(recordName: name, arrivedAt: hint?.arrivedAt ?? now,
                                          source: hint == nil ? .polling : .push))
                }
            case .refused?:
                break
            default:
                continue
            }
            if let identifier = pushHints.removeValue(forKey: name)?.notificationIdentifier {
                settled.append(identifier)
            }
        }
        environment.notifications.removeDeliveredNotifications(identifiers: settled)
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
        deliveryRecords = []
        pairedMacs = []
        pushHints = [:]
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
