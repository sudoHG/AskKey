import AskKeyDevices
import Foundation

/// A message sealed once and sent until CloudKit saves it.
struct OutgoingMessage: Hashable, Sendable {
    enum Purpose: Hashable, Sendable {
        /// The receipt for the request with this record name.
        case receipt(request: String)
        /// An approver confirmation; once saved, the flag for this pairing is set.
        case confirmation(mac: DeviceID, pairingID: PairingID)
    }

    let envelope: DeviceEnvelope
    let purpose: Purpose
}

/// The approver's inbox side (ADR 0014 → iPhone app): which verified
/// messages it accepts, what it stores before it reports them processed,
/// and what it drops when a Mac's approval ends.
extension AppModel {
    static let pendingLimitPerMac = 16
    static let pendingLimit = 64
    static let markerLimitPerMac = 16
    static let markerLimit = 64

    // MARK: Handler

    /// Verified kinds 10–14. `AskKeyDevices` checked the envelope, the
    /// signatures, the payload and the pairing ID; this checks the
    /// direction and the approval flag: a Mac sends only requests and
    /// closed messages, and only a Mac whose entry carries this iPhone's
    /// approval flag is heard. Everything after the list read runs without
    /// a suspension, so overlapping calls see each other's changes.
    func handleApproval(_ message: VerifiedApprovalMessage) async -> ApprovalMessageHandling {
        guard let services, message.envelope.recipient == services.deviceID.text else { return .failed }
        switch message.message {
        case .request(let request):
            return await accept(request, message, services: services)
        case .closed(let closed):
            return await accept(closed, message, services: services)
        case .decision, .receipt, .confirmation:
            return .refused(.unexpectedKind)
        }
    }

    /// Re-reads the list: the sender must still be on it with the same
    /// pairing ID and the approval flag, and its approval must not have
    /// ended in this process. Nil when the list cannot be read now.
    private func senderApproves(_ message: VerifiedApprovalMessage, services: DeviceServices) async -> Bool? {
        guard message.sender.isApprover, !revokedPairings.contains(message.pairingID) else { return false }
        guard let list = try? await services.registry.list(), self.services === services else { return nil }
        knownList = list
        return approves(message.senderID, pairingID: message.pairingID, in: list)
    }

    func approves(_ mac: DeviceID, pairingID: PairingID, in list: PairedDeviceList) -> Bool {
        guard let entry = list.device(mac) else { return false }
        return entry.pairingID == pairingID && entry.isApprover && !revokedPairings.contains(pairingID)
    }

    private func accept(_ request: ApprovalRequest, _ message: VerifiedApprovalMessage,
                        services: DeviceServices) async -> ApprovalMessageHandling {
        switch await senderApproves(message, services: services) {
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
        if state.markers.contains(where: { $0.macID == mac && $0.pairingID == pairing && $0.requestDigest == digest }) {
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
              pending.count < Self.pendingLimit else {
            return .refused(.bindingMismatch)
        }
        for index in displaced where state.requests[index].closed == nil {
            state.requests[index].gone = true
        }
        // The countdown runs for the deadline minus the sent time, both on
        // the Mac's clock, so this iPhone's clock offset cancels.
        let lifetime = request.deadline.timeIntervalSince(message.sentAt)
        state.requests.append(StoredRequest(recordName: recordName, macID: mac, pairingID: pairing, requestDigest: digest,
                                            launchTime: request.launchTime, countdownEnd: now.addingTimeInterval(lifetime),
                                            transportExpiry: message.expiresAt, envelope: StoredEnvelope(message.envelope)))
        // The sealed request is stored before the inbox copy is deleted.
        do {
            try environment.approvals.save(state)
        } catch {
            AppLog.failure("Storing a request", error)
            return .failed
        }
        approvals = state
        openedContent[recordName] = message
        forget(expired)
        if let receipt = try? services.sealer.sealApprovalReceipt(answering: message) {
            outbox[receipt.envelope.recordName] = OutgoingMessage(envelope: receipt.envelope,
                                                                  purpose: .receipt(request: recordName))
        }
        rebuildRequests()
        settleRequestNotifications(also: expired)
        return .processed
    }

    private func accept(_ closed: ApprovalClosed, _ message: VerifiedApprovalMessage,
                        services: DeviceServices) async -> ApprovalMessageHandling {
        switch await senderApproves(message, services: services) {
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
            guard state.markers.filter({ $0.macID == mac }).count < Self.markerLimitPerMac,
                  state.markers.count < Self.markerLimit else {
                return .refused(.bindingMismatch)
            }
            state.markers.append(StoredMarker(macID: mac, pairingID: pairing, requestDigest: digest,
                                              expiresAt: message.expiresAt))
        }
        do {
            try environment.approvals.save(state)
        } catch {
            AppLog.failure("Storing a closed request", error)
            return .failed
        }
        approvals = state
        forget(expired)
        rebuildRequests()
        settleRequestNotifications(also: expired)
        return .processed
    }

    // MARK: Revocation

    /// Runs before any removal of a Mac commits: an unpair notice, a
    /// removal here, or pairing again. Its requests are refused from now on.
    func macWillBeRemoved(_ entry: PairedDevice) async {
        revokedPairings.insert(entry.pairingID)
        dropApprovals(forMac: entry.deviceID.text)
    }

    /// Drops a Mac's requests, stored decisions, markers, unsent receipts
    /// and confirmations, and their notifications.
    func dropApprovals(forMac mac: String) {
        var state = approvals
        let dropped = state.requests.filter { $0.macID == mac }.map(\.recordName)
        state.requests.removeAll { $0.macID == mac }
        state.markers.removeAll { $0.macID == mac }
        if state != approvals { commitApprovals(state) }
        forget(dropped)
        outbox = outbox.filter { _, message in
            switch message.purpose {
            case .receipt(let request): return !dropped.contains(request)
            case .confirmation(let target, _): return target.text != mac
            }
        }
        rebuildRequests()
        settleRequestNotifications(also: dropped)
    }

    /// After an account change, a sign-out or an identity reset: every
    /// stored request, decision and marker goes.
    func dropAllApprovals() {
        guard !approvals.isEmpty || !openedContent.isEmpty || !outbox.isEmpty else { return }
        let dropped = approvals.requests.map(\.recordName)
        do {
            try environment.approvals.removeApprovals()
        } catch {
            AppLog.failure("Deleting the stored requests", error)
        }
        approvals = StoredApprovals()
        openedContent = [:]
        outbox = [:]
        nextAttempts = [:]
        decisionProblems = [:]
        openedRequest = nil
        rebuildRequests()
        settleRequestNotifications(also: dropped)
    }

    // MARK: State

    /// Saves the state; a failed save keeps the change in memory, and the
    /// stored copy is checked again at the next launch.
    func commitApprovals(_ state: StoredApprovals) {
        approvals = state
        do {
            try environment.approvals.save(state)
        } catch {
            AppLog.failure("Storing the requests", error)
        }
    }

    func forget(_ recordNames: [String]) {
        for name in recordNames {
            openedContent[name] = nil
            decisionProblems[name] = nil
            nextAttempts[name] = nil
        }
        if let opened = openedRequest, recordNames.contains(opened.id) { openedRequest = nil }
    }

    /// At launch: opens every stored request again with the stateless
    /// verifier, against the current list. A request that no longer opens,
    /// or whose Mac no longer carries the approval flag, is dropped.
    func restoreApprovals(_ services: DeviceServices) async {
        guard let list = try? await services.registry.list(), self.services === services else { return }
        knownList = list
        let now = environment.clock.now()
        let verifier = DeviceMessageVerifier(identity: services.identity, list: list)
        var state = approvals
        var dropped = state.prune(now: now)
        for entry in state.requests where openedContent[entry.recordName] == nil {
            if let message = reopen(entry, with: verifier, list: list, now: now) {
                openedContent[entry.recordName] = message
            } else {
                dropped.append(entry.recordName)
            }
        }
        state.requests.removeAll { dropped.contains($0.recordName) }
        state.markers.removeAll { marker in
            guard let mac = DeviceID(text: marker.macID), let pairing = PairingID(rawValue: marker.pairingID) else { return true }
            return !approves(mac, pairingID: pairing, in: list)
        }
        if state != approvals { commitApprovals(state) }
        forget(dropped)
        rebuildRequests(list: list)
        settleRequestNotifications(also: dropped)
    }

    private func reopen(_ entry: StoredRequest, with verifier: DeviceMessageVerifier, list: PairedDeviceList,
                        now: Date) -> VerifiedApprovalMessage? {
        guard let envelope = entry.envelope.envelope, let mac = DeviceID(text: entry.macID),
              let pairing = PairingID(rawValue: entry.pairingID), approves(mac, pairingID: pairing, in: list),
              case .approval(let message)? = try? verifier.verify(envelope, now: now),
              case .request = message.message, message.senderID == mac, message.digest == entry.requestDigest else {
            return nil
        }
        return message
    }

    /// Rebuilds the cards from the stored entries, the opened content and
    /// the list, which names each Mac by this iPhone's own name for it.
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
                                     isGone: entry.gone))
        }
        let ordered = cards.sorted { lhs, rhs in
            let (left, right) = (lhs.phase(at: now).isFinished, rhs.phase(at: now).isFinished)
            if left != right { return !left }
            return left ? lhs.countdownEnd > rhs.countdownEnd : lhs.countdownEnd < rhs.countdownEnd
        }
        if ordered != requests { requests = ordered }
        if let pendingOpen, requests.contains(where: { $0.id == pendingOpen }) {
            openedRequest = OpenedRequest(id: pendingOpen)
            self.pendingOpen = nil
        }
    }

    /// Whether the record is a request whose card still waits for a decision.
    func isPendingRequest(_ recordName: String) -> Bool {
        guard let index = approvals.index(of: recordName) else { return false }
        return !approvals.requests[index].isFinished(at: environment.clock.now())
    }

    /// Removes the delivered notifications of settled requests: finished,
    /// dropped or expired, matched by the record name in the user info.
    func settleRequestNotifications(also recordNames: [String] = []) {
        let now = environment.clock.now()
        let settled = Set(approvals.requests.filter { $0.isFinished(at: now) }.map(\.recordName)).union(recordNames)
        var identifiers: [String] = []
        for name in settled {
            if let identifier = pushHints.removeValue(forKey: name)?.notificationIdentifier { identifiers.append(identifier) }
        }
        environment.notifications.removeDeliveredNotifications(identifiers: identifiers)
    }

    /// Hides a finished card; its entry stays until its transport expiry.
    public func dismissRequest(id: String) {
        guard let index = approvals.index(of: id), approvals.requests[index].isFinished(at: environment.clock.now()) else {
            return
        }
        var state = approvals
        state.requests[index].dismissed = true
        commitApprovals(state)
        rebuildRequests()
    }
}
