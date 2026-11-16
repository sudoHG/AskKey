import AskKeyDevices
import Foundation

/// A receipt sealed once and sent until CloudKit saves it.
struct OutgoingMessage: Hashable, Sendable {
    let envelope: DeviceEnvelope
    /// The record name of the request it acknowledges.
    let request: String
}

/// The approver's inbox side (ADR 0014 → iPhone app): which verified
/// messages it accepts, what it stores before it reports them processed,
/// and what it drops when a Mac's approval ends.
extension AppModel {
    static let pendingLimitPerMac = 16
    static let pendingLimit = 64
    static let markerLimitPerMac = 16
    static let markerLimit = 64
    /// Stored requests, finished ones included, so a Mac that keeps sending
    /// and closing requests cannot grow the store without bound.
    static let storedLimitPerMac = 32
    static let storedLimit = 128
    /// How long a tapped notification's sheet shows the loading state at most.
    nonisolated static let pendingOpenLifetime: TimeInterval = 60

    // MARK: Handler

    /// Verified kinds 10–13. `AskKeyDevices` checked the envelope, the
    /// signatures, the payload and the pairing ID; this checks the
    /// direction and the approval flag: a Mac sends only requests and
    /// closed messages, and only a Mac whose entry carries this iPhone's
    /// approval flag is heard. Everything after the list read runs without
    /// a suspension, so overlapping calls see each other's changes. A call
    /// from a messenger an account change replaced, one made while the
    /// account is unavailable, or one while the stored state cannot be read
    /// fails, and the message stays in the inbox.
    func handleApproval(_ message: VerifiedApprovalMessage, generation: Int) async -> ApprovalMessageHandling {
        guard let services, isCurrent(services, generation: generation),
              message.envelope.recipient == services.deviceID.text else { return .failed }
        switch message.message {
        case .request(let request):
            return await accept(request, message, services: services, generation: generation)
        case .closed(let closed):
            return await accept(closed, message, services: services, generation: generation)
        case .decision, .receipt:
            return .refused(.unexpectedKind)
        }
    }

    private func isCurrent(_ services: DeviceServices, generation: Int) -> Bool {
        self.services === services && services.generation == generation && accountNotice == nil && approvalsReadable
    }

    /// Re-reads the list: the sender must still be on it with the same
    /// pairing ID and the approval flag, and its approval must not have
    /// ended in this process. Nil when the list cannot be read now or the
    /// services changed meanwhile.
    private func senderApproves(_ message: VerifiedApprovalMessage, services: DeviceServices,
                                generation: Int) async -> Bool? {
        guard message.sender.isApprover, !revokedPairings.contains(message.pairingID) else { return false }
        guard let list = try? await services.registry.list(), isCurrent(services, generation: generation) else { return nil }
        knownList = list
        return approves(message.senderID, pairingID: message.pairingID, in: list)
    }

    func approves(_ mac: DeviceID, pairingID: PairingID, in list: PairedDeviceList) -> Bool {
        guard let entry = list.device(mac) else { return false }
        return entry.pairingID == pairingID && entry.isApprover && !revokedPairings.contains(pairingID)
    }

    private func accept(_ request: ApprovalRequest, _ message: VerifiedApprovalMessage,
                        services: DeviceServices, generation: Int) async -> ApprovalMessageHandling {
        switch await senderApproves(message, services: services, generation: generation) {
        case nil: return .failed
        case false?: return .refused(.bindingMismatch)
        case true?: break
        }
        let now = environment.clock.now()
        var state = approvals
        let expired = state.prune(now: now)
        let recordName = message.messageID.text
        let mac = message.senderID.text
        let pairing = message.pairingID.rawValue
        let digest = message.digest
        // A re-inserted request is never shown twice.
        if state.requests.contains(where: { $0.recordName == recordName || ($0.macID == mac && $0.requestDigest == digest) }) {
            return .refused(.replayed)
        }
        // A closed message that arrived first ended it; the marker stays
        // until its own expiry.
        if let marker = state.markers.first(where: { $0.macID == mac && $0.pairingID == pairing && $0.requestDigest == digest }) {
            historyArrivedAfterClose(request, message, marker: marker)
            return .processed
        }
        // Launch times: an earlier Mac App process than one already seen
        // is refused; a later one leaves the older cards gone.
        let fromMac = state.requests.indices.filter { state.requests[$0].macID == mac }
        let newest = fromMac.map { state.requests[$0].launchTime }.max()
        if let newest, request.launchTime < newest { return .refused(.bindingMismatch) }
        let displaced = fromMac.filter { state.requests[$0].launchTime < request.launchTime }
        let pending = state.requests.indices.filter { !displaced.contains($0) && !state.requests[$0].isFinished(at: now) }
        guard pending.filter({ state.requests[$0].macID == mac }).count < Self.pendingLimitPerMac,
              pending.count < Self.pendingLimit, fromMac.count < Self.storedLimitPerMac,
              state.requests.count < Self.storedLimit else {
            return .refused(.bindingMismatch)
        }
        for index in displaced where state.requests[index].closed == nil {
            state.requests[index].gone = true
        }
        // The countdown runs for the deadline minus the sent time, both on
        // the Mac's clock, so this iPhone's clock offset cancels.
        let lifetime = request.deadline.timeIntervalSince(message.sentAt)
        let countdownEnd = now.addingTimeInterval(lifetime)
        state.requests.append(StoredRequest(recordName: recordName, macID: mac, pairingID: pairing, requestDigest: digest,
                                            launchTime: request.launchTime, countdownEnd: countdownEnd,
                                            transportExpiry: message.expiresAt, envelope: StoredEnvelope(message.envelope)))
        // The sealed request is stored before the inbox copy is deleted.
        do {
            try persist(state)
        } catch {
            AppLog.failure("Storing a request", error)
            return .failed
        }
        approvals = state
        historyAccepted(request, message, countdownEnd: countdownEnd)
        openedContent[recordName] = message
        forget(expired)
        if let receipt = try? services.sealer.sealApprovalReceipt(answering: message) {
            outbox[receipt.envelope.recordName] = OutgoingMessage(envelope: receipt.envelope, request: recordName)
        }
        rebuildRequests()
        settleRequestNotifications(also: expired)
        return .processed
    }

    private func accept(_ closed: ApprovalClosed, _ message: VerifiedApprovalMessage,
                        services: DeviceServices, generation: Int) async -> ApprovalMessageHandling {
        switch await senderApproves(message, services: services, generation: generation) {
        case nil: return .failed
        case false?: return .refused(.bindingMismatch)
        case true?: break
        }
        var state = approvals
        let expired = state.prune(now: environment.clock.now())
        let mac = message.senderID.text
        let pairing = message.pairingID.rawValue
        let digest = closed.requestDigest
        // Only the request's own sender, with its pairing ID, closes it.
        if let index = state.requests.firstIndex(where: {
            $0.macID == mac && $0.pairingID == pairing && $0.requestDigest == digest
        }) {
            guard state.requests[index].closed == nil else { return .refused(.replayed) }
            if closed.outcome == .applied {
                // The Mac applied this iPhone's own decision: never another
                // code, and never longer than the signed ceiling.
                guard let decision = state.requests[index].decision, decision.code == closed.appliedCode?.rawValue,
                      closed.appliedDuration <= decision.durationCeiling else {
                    return .refused(.bindingMismatch)
                }
            }
            state.requests[index].closed = StoredClosed(closed)
        } else if state.requests.contains(where: { $0.requestDigest == digest }) {
            // Another Mac's request: only its own sender closes it.
            return .refused(.bindingMismatch)
        } else {
            guard !state.markers.contains(where: { $0.macID == mac && $0.pairingID == pairing && $0.requestDigest == digest })
            else { return .refused(.replayed) }
            if let handled = historyClosedLate(closed, mac: mac, pairing: pairing, digest: digest) { return handled }
            guard state.markers.filter({ $0.macID == mac }).count < Self.markerLimitPerMac,
                  state.markers.count < Self.markerLimit else {
                return .refused(.bindingMismatch)
            }
            state.markers.append(StoredMarker(macID: mac, pairingID: pairing, requestDigest: digest,
                                              expiresAt: message.expiresAt, closed: StoredClosed(closed)))
        }
        do {
            try persist(state)
        } catch {
            AppLog.failure("Storing a closed request", error)
            return .failed
        }
        approvals = state
        recordHistory()
        forget(expired)
        rebuildRequests()
        settleRequestNotifications(also: expired)
        return .processed
    }

    // MARK: Revocation

    /// Runs before any removal of a Mac commits: an unpair notice, a
    /// removal here, or pairing again. Its requests are refused from now on.
    func macWillBeRemoved(_ entry: PairedDevice) async {
        revoke(entry)
    }

    /// Refuses the pairing's messages from now on and drops the Mac's
    /// requests, without suspending. Running it again changes nothing.
    func revoke(_ entry: PairedDevice) {
        revokedPairings.insert(entry.pairingID)
        dropApprovals(forMac: entry.deviceID.text)
    }

    /// Drops a Mac's requests, stored decisions, markers, unsent receipts
    /// and their notifications; requests that had already ended get their
    /// history entries first.
    func dropApprovals(forMac mac: String) {
        var state = approvals
        let dropped = state.requests.filter { $0.macID == mac }.map(\.recordName)
        historyWillDrop(state.requests.filter { $0.macID == mac })
        closePage(of: dropped)
        state.requests.removeAll { $0.macID == mac }
        state.markers.removeAll { $0.macID == mac }
        if state != approvals { commitApprovals(state) }
        forget(dropped)
        outbox = outbox.filter { _, message in !dropped.contains(message.request) }
        rebuildRequests()
        settleRequestNotifications(also: dropped)
    }

    /// After an account change, a sign-out or an identity reset: every
    /// stored request, decision and marker goes.
    func dropAllApprovals() {
        guard !approvals.isEmpty || !openedContent.isEmpty || !outbox.isEmpty || !approvalsReadable else { return }
        let dropped = approvals.requests.map(\.recordName)
        do {
            try environment.approvals.removeApprovals()
            approvalsReadable = true
        } catch {
            // A copy that survives is saved under the old account, which
            // `loadApprovals` drops.
            AppLog.failure("Deleting the stored requests", error)
        }
        approvals = StoredApprovals()
        openedContent = [:]
        outbox = [:]
        nextAttempts = [:]
        decisionProblems = [:]
        openedRequest = nil
        opening = nil
        uncheckedRequests = []
        rebuildRequests()
        settleRequestNotifications(also: dropped)
    }

    // MARK: State

    /// Writes the state under the current iCloud account. Nothing is
    /// written while the stored state cannot be read.
    func persist(_ state: StoredApprovals) throws {
        guard approvalsReadable else { throw CocoaError(.fileReadUnknown) }
        var state = state
        state.account = environment.localState.inboxPosition?.userRecordName
        try environment.approvals.save(state)
    }

    /// Saves the state; a failed save keeps the change in memory, and the
    /// stored copy is checked again at the next launch.
    func commitApprovals(_ state: StoredApprovals) {
        approvals = state
        do {
            try persist(state)
        } catch {
            AppLog.failure("Storing the requests", error)
        }
    }

    /// Loads the stored state. A state saved under another iCloud account
    /// is deleted; one that cannot be read now blocks the approver until a
    /// later load succeeds.
    func loadApprovals() {
        guard let state = environment.approvals.load() else {
            approvalsReadable = false
            approvals = StoredApprovals()
            return
        }
        approvalsReadable = true
        if !state.isEmpty, state.account != environment.localState.inboxPosition?.userRecordName {
            do {
                try environment.approvals.removeApprovals()
            } catch {
                AppLog.failure("Deleting the stored requests", error)
            }
            approvals = StoredApprovals()
            return
        }
        approvals = state
    }

    /// Forgets dropped or expired requests. An open page whose request had
    /// already ended keeps its outcome until the person closes it (decision
    /// 7 of #344), even once the stored request expired; every other open
    /// page of a forgotten request closes. A revocation closes the page
    /// first (`closePage(of:)`).
    func forget(_ recordNames: [String]) {
        for name in recordNames {
            openedContent[name] = nil
            decisionProblems[name] = nil
            nextAttempts[name] = nil
            uncheckedRequests.remove(name)
        }
        if let opened = openedRequest, recordNames.contains(opened.id),
           requests.first(where: { $0.id == opened.id })?.phase(at: environment.clock.now()).isFinished != true {
            openedRequest = nil
        }
        if let opening, recordNames.contains(opening.id) { self.opening = nil }
    }

    /// Closes the open page of a request whose Mac no longer approves.
    func closePage(of recordNames: [String]) {
        if let opened = openedRequest, recordNames.contains(opened.id) { openedRequest = nil }
    }

    /// At launch: opens every stored request again with the stateless
    /// verifier, against the current list. A request that no longer opens,
    /// or whose Mac no longer carries the approval flag, is dropped.
    func restoreApprovals(_ services: DeviceServices) async {
        guard let list = try? await services.registry.list(), self.services === services, approvalsReadable else { return }
        knownList = list
        let now = environment.clock.now()
        let verifier = DeviceMessageVerifier(identity: services.identity, list: list)
        var state = approvals
        var dropped = state.prune(now: now)
        let expired = dropped
        for entry in state.requests where openedContent[entry.recordName] == nil {
            do {
                if let message = try reopen(entry, with: verifier, list: list, now: now) {
                    openedContent[entry.recordName] = message
                } else {
                    dropped.append(entry.recordName)
                }
            } catch {
                // This iPhone's own key failed, not the request: keep the
                // stored state for after the reset's decision.
                return identityBecameUnusable()
            }
        }
        historyWillDrop(state.requests.filter { dropped.contains($0.recordName) })
        state.requests.removeAll { dropped.contains($0.recordName) }
        state.markers.removeAll { marker in
            guard let mac = DeviceID(text: marker.macID), let pairing = PairingID(rawValue: marker.pairingID) else { return true }
            return !approves(mac, pairingID: pairing, in: list)
        }
        if state != approvals { commitApprovals(state) }
        recordHistory()
        closePage(of: dropped.filter { !expired.contains($0) })
        forget(dropped)
        rebuildRequests(list: list)
        settleRequestNotifications(also: dropped)
    }

    /// Throws `DeviceIdentityError` when this iPhone's own key fails.
    private func reopen(_ entry: StoredRequest, with verifier: DeviceMessageVerifier, list: PairedDeviceList,
                        now: Date) throws -> VerifiedApprovalMessage? {
        guard let envelope = entry.envelope.envelope, let mac = DeviceID(text: entry.macID),
              let pairing = PairingID(rawValue: entry.pairingID), approves(mac, pairingID: pairing, in: list),
              case .approval(let message) = try verifier.verify(envelope, now: now),
              case .request = message.message, message.senderID == mac, message.digest == entry.requestDigest else {
            return nil
        }
        return message
    }

    /// Rebuilds the cards from the stored entries, the opened content and
    /// the list, which names each Mac by this iPhone's own name for it.
    /// A finished card stays here, so its open page keeps its outcome until
    /// the person closes it, while the Requests tab no longer lists it
    /// (decision 7 of #344, `activeRequests(at:)`); after its stored request
    /// expired, the page keeps the last card it showed. Nothing stored
    /// changes when the page closes. Entries an earlier build let the person
    /// dismiss stay hidden.
    func rebuildRequests(list: PairedDeviceList? = nil) {
        if let list { knownList = list }
        let now = environment.clock.now()
        var cards: [RequestCard] = []
        for entry in approvals.requests where !entry.dismissed {
            guard let message = openedContent[entry.recordName], case .request(let request) = message.message,
                  let device = knownList?.device(message.senderID), device.pairingID.rawValue == entry.pairingID else {
                continue
            }
            cards.append(RequestCard(id: entry.recordName, macID: entry.macID, macName: device.displayName,
                                     macPairedAt: device.pairedAt, display: RequestDisplay(request),
                                     countdownEnd: entry.countdownEnd, decision: entry.decision?.decisionCode,
                                     isSent: entry.lastSentAt != nil, outcome: entry.closed.flatMap(RequestOutcome.init),
                                     isGone: entry.gone, isChecking: uncheckedRequests.contains(entry.recordName)))
        }
        let ordered = cards.sorted { lhs, rhs in
            let (left, right) = (lhs.phase(at: now).isFinished, rhs.phase(at: now).isFinished)
            if left != right { return !left }
            return left ? lhs.countdownEnd > rhs.countdownEnd : lhs.countdownEnd < rhs.countdownEnd
        }
        if ordered != requests { requests = ordered }
        // The tapped request's card replaces its loading or unavailable state.
        if let opening, requests.contains(where: { $0.id == opening.id }) { self.opening = nil }
    }

    /// Whether the record is a request whose card still waits for a decision.
    func isPendingRequest(_ recordName: String) -> Bool {
        guard let index = approvals.index(of: recordName) else { return false }
        return !approvals.requests[index].isFinished(at: environment.clock.now())
    }

    /// Removes the delivered notifications of settled requests: finished,
    /// dropped or expired, matched by the record name in the user info.
    /// Settled names are kept for this process, so a notification found
    /// later, for example at the first activation after a cold launch,
    /// is removed as soon as it is seen.
    func settleRequestNotifications(also recordNames: [String] = []) {
        let now = environment.clock.now()
        let settled = Set(approvals.requests.filter { $0.isFinished(at: now) }.map(\.recordName)).union(recordNames)
        settledRequests.formUnion(settled)
        removeNotifications(of: settled)
    }

    /// Removes every delivered notification known for these record names.
    func removeNotifications(of recordNames: some Sequence<String>) {
        var identifiers: [String] = []
        for name in recordNames {
            if let identifier = pushHints.removeValue(forKey: name)?.notificationIdentifier { identifiers.append(identifier) }
            identifiers += extraNotifications.removeValue(forKey: name) ?? []
        }
        environment.notifications.removeDeliveredNotifications(identifiers: identifiers)
    }
}
