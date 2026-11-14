import AskKeyBroker
import AskKeyDevices
import AskKeyVault
import Foundation

/// Sending eligible read requests to approvers and the schedules around them
/// (ADR 0014 → When a request goes to an approver, Sending and the return
/// path). Everything here runs on the main actor with the coordinator, so
/// the outstanding table changes without suspending between a check and its
/// effect.
extension DeviceCoordinator {
    /// An unlocked Mac sends a request still pending after this long.
    static let remoteSendDelay: TimeInterval = 20
    static let maximumOutstandingPerApprover = 16
    static let remoteRetryInterval: TimeInterval = 2
    static let remoteLoopInterval: TimeInterval = 1
    static let fastFetchInterval: TimeInterval = 1
    static let slowFetchInterval: TimeInterval = 3
    /// Known records are fetched every second while a request was sealed
    /// less than this long ago.
    static let fastFetchWindow: TimeInterval = 60
    static let namedFetchBatch = 100

    // MARK: Messenger

    func makeMessenger(identity: PairingAuthorizingIdentity, registry: PairedDeviceRegistry, inbox: any DeviceInbox,
                       clock: any DeviceClock, inboxToken: InboxChangeToken? = nil) -> DeviceMessenger {
        DeviceMessenger(
            identity: identity, platform: .macOS, registry: registry, transport: inbox, clock: clock,
            inboxToken: inboxToken,
            approvalHandler: { [weak self] message in
                guard let self else { return .failed }
                return await self.handleApprovalMessage(message)
            },
            removalHook: { [weak self] entry in
                await self?.deviceWillBeRemoved(entry)
            }
        )
    }

    /// ADR 0014 → Mac App: a Mac registers for pushes once it has an
    /// identity, so one that never pairs registers none.
    func registerForRemoteNotificationsOnce() {
        guard !registeredForRemoteNotifications else { return }
        registeredForRemoteNotifications = true
        environment.registerForRemoteNotifications()
    }

    // MARK: Approvers

    /// Loads the Broker's active-approver set from the list once the services
    /// are ready with the list's account (ADR 0014 → Approvers).
    func activateApproversIfNeeded() {
        guard services != nil, availability == .ready, account == .available, !approversLoaded else { return }
        do {
            try vault.activateStoredApprovers()
            approversLoaded = true
        } catch {
            environment.log(.approverActivationFailed)
        }
    }

    /// An account change, sign-out or restriction: empties the set first,
    /// then forgets every outstanding request without sending, because
    /// nothing is sent while the account is unavailable. The flags stay.
    func suspendRemoteApproval() {
        vault.approvalRequests.removeAllActiveApprovers()
        approversLoaded = false
        // The requests still pending stay on the Mac, also once the account
        // is back; their outstanding entries are forgotten.
        let seen = remoteRequests.mapValues { RemoteRequestTrack(pending: $0.pending, phase: .stayingOnMac) }
        dropRemoteState()
        remoteRequests = seen
        if approverConfirmation?.isActive == true { endApproverAttempt(.unavailable) }
    }

    /// The services stopped or were replaced.
    func stopRemoteApproval() {
        approversLoaded = false
        dropRemoteState()
        if approverConfirmation != nil {
            approverGeneration += 1
            finishApproverAttempt()
            approverConfirmation = nil
        }
    }

    private func dropRemoteState() {
        remoteLoopTask?.cancel()
        remoteLoopTask = nil
        remoteRequests = [:]
        closedMessages = [:]
        nextKnownRecordFetch = nil
        publishRemoteStatus()
        updateRemoteActivity()
    }

    /// Approvers on the list that are in the Broker's set, with their generations.
    func activeApprovers(in list: [PairedDevice]) -> [(device: PairedDevice, generation: UInt64)] {
        list.filter(\.isApprover).compactMap { device in
            vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue).map { (device, $0) }
        }
    }

    var hasActiveApprover: Bool { !activeApprovers(in: listedDevices).isEmpty }

    /// Device services ready, the list's account available, the set loaded
    /// and agent access not paused (ADR 0014 → eligibility).
    var remoteSendingAllowed: Bool {
        guard services != nil, availability == .ready, account == .available, approversLoaded else { return false }
        return (try? vault.agentAccessPolicyState().isPaused) == false
    }

    // MARK: Requests

    /// The Broker's pending requests changed, or the coordinator checks them
    /// on its schedule: new read requests are tracked, due ones are sent, and
    /// requests that left pending are closed.
    package func approvalRequestsChanged() {
        reconcileRemoteRequests()
        startRemoteLoopIfNeeded()
    }

    func reconcileRemoteRequests() {
        guard services != nil else { return }
        let pending = vault.approvalRequests.pendingRequests()
        let pendingIDs = Set(pending.map(\.requestID))
        for (requestID, track) in remoteRequests where !pendingIDs.contains(requestID) && track.ended == nil {
            requestLeftPending(requestID)
        }
        let now = self.now
        let approverExists = hasActiveApprover
        for request in pending where remoteRequests[request.requestID] == nil {
            // A request that appears while no approver is active, or that
            // is not a read with a display summary, stays on the Mac.
            guard approverExists, request.request.operation == .read, request.request.display != nil else {
                remoteRequests[request.requestID] = RemoteRequestTrack(pending: request, phase: .stayingOnMac)
                continue
            }
            if environment.isScreenUnlocked() {
                remoteRequests[request.requestID] = RemoteRequestTrack(
                    pending: request, phase: .waiting(sendAt: now.addingTimeInterval(Self.remoteSendDelay)))
            } else {
                remoteRequests[request.requestID] = RemoteRequestTrack(pending: request, phase: .sending)
                startDelivery(request.requestID)
            }
        }
        for (requestID, track) in remoteRequests {
            if case .waiting(let sendAt) = track.phase, now >= sendAt { beginWaitingDelivery(requestID) }
        }
        updateRemoteActivity()
    }

    /// The screen locked: every request still waiting goes out now.
    package func screenDidLock() {
        for (requestID, track) in remoteRequests {
            if case .waiting = track.phase { beginWaitingDelivery(requestID) }
        }
        startRemoteLoopIfNeeded()
    }

    /// A screen unlock or a wake fetches the known records at once.
    package func screenDidUnlockOrWake() {
        guard !remoteRequests.isEmpty else { return }
        nextKnownRecordFetch = nil
        Task { [weak self] in await self?.remoteApprovalTick() }
    }

    private func beginWaitingDelivery(_ requestID: String) {
        guard var track = remoteRequests[requestID], case .waiting = track.phase else { return }
        track.phase = .sending
        remoteRequests[requestID] = track
        startDelivery(requestID)
    }

    private func startDelivery(_ requestID: String) {
        Task { [weak self] in await self?.deliverRemoteRequest(requestID) }
    }

    /// Seals the request once for every active approver (or only `approver`,
    /// for a replacement) and sends it. The list is read first; from the
    /// re-read of the request's status to the recorded entries nothing
    /// suspends, so a request decided on the Mac before then never leaves it.
    func deliverRemoteRequest(_ requestID: String, only approver: DeviceID? = nil) async {
        guard let services, remoteRequests[requestID] != nil else { return }
        let lifecycle = self.lifecycle
        let list = try? await services.registry.list()
        guard lifecycle == self.lifecycle, self.services === services, var track = remoteRequests[requestID],
              track.ended == nil else { return }
        let now = self.now
        let content = (try? vault.agentAccessPolicyState()).flatMap {
            RemoteApprovalRequestContent(pending: track.pending, policy: $0.policy)
        }
        guard let list, let content, remoteSendingAllowed, let deadline = track.deadline, deadline > now,
              (try? vault.approvalRequests.status(requestID: track.requestID, capability: track.pending.capability)) == .pending
        else {
            if approver == nil, track.phase == .sending { track.phase = .stayingOnMac }
            remoteRequests[requestID] = track
            updateRemoteActivity()
            return
        }
        var sealed: [MessageID] = []
        for (device, generation) in activeApprovers(in: list.devices) {
            guard approver.map({ $0 == device.deviceID }) ?? true,
                  !track.entries.contains(where: { $0.approverID == device.deviceID && !$0.decided }),
                  outstandingCount(for: device.deviceID) < Self.maximumOutstandingPerApprover else { continue }
            do {
                let request = try services.messenger.sealer.sealApprovalRequest(
                    content.display, bindingDigest: content.bindingDigest, deadline: deadline, launchTime: launchTime,
                    offers: content.offers, timedDuration: content.timedDuration, to: device)
                track.entries.append(OutstandingRemoteRequest(
                    recipient: device, generation: generation, responseID: request.request.responseID,
                    receiptID: ApprovalReceipt.receiptID(for: request.request.responseID),
                    requestDigest: request.requestDigest, offers: request.request.offers,
                    timedDuration: request.request.timedDuration, envelope: request.sealed.envelope, sealedAt: now))
                sealed.append(request.request.responseID)
            } catch {
                environment.log(.remoteRequestNotSealed)
            }
        }
        if track.phase == .sending { track.phase = sealed.isEmpty && track.entries.isEmpty ? .stayingOnMac : .sent }
        remoteRequests[requestID] = track
        publishRemoteStatus()
        updateRemoteActivity()
        startRemoteLoopIfNeeded()
        for responseID in sealed {
            await transmitRemoteRequest(requestID, responseID: responseID)
        }
    }

    func outstandingCount(for device: DeviceID) -> Int {
        remoteRequests.values.reduce(0) { $0 + $1.entries.filter { $0.approverID == device }.count }
    }

    /// Sends a sealed request's exact bytes; a failure is retried every two
    /// seconds, or after CloudKit's retry-after, until the deadline.
    func transmitRemoteRequest(_ requestID: String, responseID: MessageID) async {
        guard let services, var track = remoteRequests[requestID],
              let index = track.entries.firstIndex(where: { $0.responseID == responseID }) else { return }
        let envelope = track.entries[index].envelope
        track.entries[index].delivery = .sending
        remoteRequests[requestID] = track
        let lifecycle = self.lifecycle
        var delivery = OutstandingRemoteRequest.Delivery.sent
        do {
            try await services.inbox.send(envelope)
        } catch DeviceTransportError.rateLimited(let retryAfter) {
            delivery = .retry(at: now.addingTimeInterval(max(retryAfter ?? 0, Self.remoteRetryInterval)))
        } catch {
            delivery = .retry(at: now.addingTimeInterval(Self.remoteRetryInterval))
        }
        guard lifecycle == self.lifecycle, var current = remoteRequests[requestID],
              let position = current.entries.firstIndex(where: { $0.responseID == responseID }) else { return }
        current.entries[position].delivery = delivery
        if delivery == .sent, current.entries[position].sentAt == nil { current.entries[position].sentAt = now }
        remoteRequests[requestID] = current
        publishRemoteStatus()
    }

    // MARK: Schedule

    /// Whether the schedule has work: a request waiting, being sealed or
    /// outstanding, or a closing message not yet saved.
    var remoteNeedsLoop: Bool {
        !closedMessages.isEmpty || remoteRequests.values.contains { track in
            switch track.phase {
            case .waiting, .sending: return true
            case .sent: return !track.entries.isEmpty
            case .stayingOnMac: return false
            }
        }
    }

    func startRemoteLoopIfNeeded() {
        updateRemoteActivity()
        guard environment.automaticPolling, remoteLoopTask == nil, remoteNeedsLoop else { return }
        let sleep = environment.sleep
        remoteLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleep(Self.remoteLoopInterval)
                guard let self, !Task.isCancelled, self.remoteNeedsLoop else { break }
                await self.remoteApprovalTick()
            }
            self?.remoteLoopTask = nil
        }
    }

    /// One turn of the schedule: checks the Broker's requests, resends what
    /// failed, retries closing messages and fetches the known records when due.
    func remoteApprovalTick() async {
        guard services != nil else { return }
        reconcileRemoteRequests()
        let now = self.now
        for (requestID, track) in remoteRequests {
            for entry in track.entries where !entry.decided {
                guard case .retry(let at) = entry.delivery, at <= now, track.deadline.map({ now < $0 }) == true else { continue }
                Task { [weak self] in await self?.transmitRemoteRequest(requestID, responseID: entry.responseID) }
            }
        }
        for (messageID, message) in closedMessages {
            guard let at = message.retryAt, at <= now else { continue }
            guard now < message.envelope.expiresAt else {
                closedMessages[messageID] = nil
                continue
            }
            Task { [weak self] in await self?.transmitClosedMessage(messageID) }
        }
        await fetchKnownRecordsIfDue()
        updateRemoteActivity()
    }

    /// While a request needs it, from eligibility until it is decided,
    /// closed or expires, the process activity is held.
    func updateRemoteActivity() {
        let approverExists = hasActiveApprover
        let needed = remoteRequests.values.contains { track in
            switch track.phase {
            case .waiting: return approverExists
            case .sending: return true
            case .sent: return !track.entries.isEmpty
            case .stayingOnMac: return false
            }
        }
        if needed, remoteActivity == nil {
            remoteActivity = environment.processActivity.begin()
        } else if !needed, let activity = remoteActivity {
            remoteActivity = nil
            environment.processActivity.end(activity)
        }
    }

    // MARK: Known records

    /// Fetches the decision record of every outstanding request and the
    /// receipt record of every request without a receipt, at most 100 names
    /// per call: every second while a request was sealed less than a minute
    /// ago, otherwise every 3 seconds, and never before CloudKit's
    /// retry-after (ADR 0014 → Polling the known records).
    func fetchKnownRecordsIfDue() async {
        guard !isFetchingKnownRecords, let services, account == .available else { return }
        let start = now
        if let next = nextKnownRecordFetch, start < next { return }
        let entries = remoteRequests.values.flatMap(\.entries).filter { !$0.decided }
        let names = entries.flatMap { entry in
            [entry.responseID.text] + (entry.deliveredAt == nil ? [entry.receiptID.text] : [])
        }
        guard !names.isEmpty else {
            nextKnownRecordFetch = nil
            return
        }
        let fast = entries.contains { start.timeIntervalSince($0.sealedAt) < Self.fastFetchWindow }
        var wait = fast ? Self.fastFetchInterval : Self.slowFetchInterval
        isFetchingKnownRecords = true
        defer { isFetchingKnownRecords = false }
        let lifecycle = self.lifecycle
        let messenger = services.messenger
        var index = 0
        while index < names.count {
            let batch = Array(names[index..<min(index + Self.namedFetchBatch, names.count)])
            index += batch.count
            do {
                let report = try await messenger.fetchNamedMessages(batch)
                guard lifecycle == self.lifecycle else { return }
                for case .refused(let refusal) in report.outcomes.values { environment.log(.messageRefused(refusal)) }
                if let retryAfter = report.retryAfter {
                    wait = max(wait, retryAfter)
                    break
                }
            } catch DeviceTransportError.rateLimited(let retryAfter) {
                wait = max(wait, retryAfter ?? Self.slowFetchInterval)
                break
            } catch DeviceIdentityError.unusable {
                guard lifecycle == self.lifecycle else { return }
                identityBecameUnusable()
                return
            } catch {
                guard lifecycle == self.lifecycle else { return }
                environment.log(.knownRecordFetchFailed)
                break
            }
        }
        guard lifecycle == self.lifecycle else { return }
        nextKnownRecordFetch = start.addingTimeInterval(wait)
    }

    // MARK: Publishing

    func publishRemoteStatus() {
        let names = Dictionary(listedDevices.map { ($0.deviceID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var statuses: [String: RemoteApprovalStatus] = [:]
        for (requestID, track) in remoteRequests where !track.entries.isEmpty {
            statuses[requestID] = RemoteApprovalStatus(approvers: track.entries.map { entry in
                RemoteApprovalStatus.Approver(deviceID: entry.approverID,
                                              displayName: names[entry.approverID] ?? entry.recipient.displayName,
                                              sentAt: entry.sentAt, deliveredAt: entry.deliveredAt)
            })
        }
        if statuses != remoteApprovals { remoteApprovals = statuses }
    }
}
