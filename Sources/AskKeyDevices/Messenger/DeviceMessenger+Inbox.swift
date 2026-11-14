import Foundation

extension DeviceMessenger {
    enum Outcome {
        case processed
        /// `authenticated` tells whether the sender's signature verified.
        case refused(DeviceMessageRefusal, authenticated: Bool)
        case held
        /// The same message ID is being handled by another fetch right now.
        /// It is not deleted and does not count as a failure.
        case busy
    }

    static let failureLimit = 3

    /// Fetches the inbox since `inboxToken`, page by page, and processes
    /// every message. Processed and refused messages are deleted. The token
    /// advances only past pages whose messages, and every earlier page's,
    /// were all processed or refused: a held or failed message keeps the old
    /// token, so a later poll fetches it again, and a message that fails
    /// three times is refused. Held messages are retried as later pages
    /// arrive. The report gives each fetched message's outcome: processed,
    /// refused, kept for an open pairing session, or failed; only failures
    /// count toward the three. An expired token leads to one full fetch
    /// from no token. A poll that starts while another is running returns
    /// an empty report. Throws `DeviceIdentityError` when this device's own
    /// key no longer works, and transport errors.
    public func poll() async throws -> InboxReport {
        guard !isPolling else { return InboxReport() }
        isPolling = true
        defer { isPolling = false }
        await advanceTimers()
        var report = InboxReport()
        var cursor = inboxToken
        var restarted = false
        var committable = true
        var held: [DeviceEnvelope] = []
        while true {
            let changes: InboxChanges
            do {
                changes = try await transport.fetchInboxChanges(of: deviceID, since: cursor)
            } catch DeviceTransportError.changeTokenExpired where !restarted {
                cursor = nil
                restarted = true
                committable = true
                held = []
                continue
            }
            let page = try await process(changes.envelopes, malformed: changes.malformedRecordNames,
                                         failed: changes.failedRecordNames, carrying: held, into: &report)
            held = page.held
            committable = committable && page.settled
            if committable, held.isEmpty {
                inboxToken = changes.newToken
            }
            cursor = changes.newToken
            guard changes.moreComing else { break }
        }
        report.held = held.count
        await advanceTimers()
        return report
    }

    /// Processes one page, or the records of a named fetch, with the
    /// messages still held from earlier pages, and deletes what settled.
    /// Pairing messages go first, in protocol order (a reveal before a
    /// confirmation), then approval-closed messages, then the rest; held
    /// messages are retried after any message took effect.
    func process(_ envelopes: [DeviceEnvelope], malformed: [String], failed: [String], carrying carried: [DeviceEnvelope],
                 into report: inout InboxReport) async throws -> (settled: Bool, held: [DeviceEnvelope]) {
        let fetchedAt = clock.now()
        for envelope in envelopes where firstFetched[envelope.recordName] == nil {
            firstFetched[envelope.recordName] = fetchedAt
        }
        var deletable = malformed
        report.refusals += malformed.map { _ in DeviceMessageRefusal.malformed }
        for name in malformed { report.outcomes[name] = .refused(.malformed) }
        var settled = failed.isEmpty
        report.failed += failed.count
        for name in failed { report.outcomes[name] = .failed }
        let fetchedNames = Set(envelopes.map(\.recordName))
        var pending = (carried.filter { !fetchedNames.contains($0.recordName) } + envelopes).enumerated()
            .sorted { (Self.rank($0.element), $0.offset) < (Self.rank($1.element), $1.offset) }
            .map(\.element)
        var progressed = true
        while progressed, !pending.isEmpty {
            progressed = false
            var held: [DeviceEnvelope] = []
            for envelope in pending {
                var outcome: Outcome
                do {
                    outcome = try await processOne(envelope)
                } catch let error as DeviceIdentityError {
                    throw error
                } catch {
                    let failures = (failureCounts[envelope.recordName] ?? 0) + 1
                    failureCounts[envelope.recordName] = failures
                    guard failures >= Self.failureLimit else {
                        report.failed += 1
                        report.outcomes[envelope.recordName] = .failed
                        settled = false
                        continue
                    }
                    outcome = .refused(.repeatedFailure, authenticated: false)
                }
                switch outcome {
                case .processed:
                    report.processed += 1
                    report.outcomes[envelope.recordName] = .processed
                    deletable.append(envelope.recordName)
                    progressed = true
                case .refused(let refusal, _):
                    report.refusals.append(refusal)
                    report.outcomes[envelope.recordName] = .refused(refusal)
                    deletable.append(envelope.recordName)
                case .held:
                    report.outcomes[envelope.recordName] = .keptForSession
                    held.append(envelope)
                case .busy:
                    report.failed += 1
                    report.outcomes[envelope.recordName] = .failed
                    settled = false
                }
            }
            pending = held
        }
        for name in deletable {
            firstFetched[name] = nil
            failureCounts[name] = nil
        }
        if !deletable.isEmpty {
            try await transport.deleteMessages(deletable, from: deviceID)
        }
        return (settled, pending)
    }

    /// Within one fetch, pairing kinds come first (ADR 0013), then
    /// approval-closed, so a closed message stored before its request keeps
    /// the request from being shown (ADR 0014), then every other kind.
    static func rank(_ envelope: DeviceEnvelope) -> Int {
        let order: [MessageKind] = [.pairingRequest, .pairingChallenge, .pairingReveal, .pairingConfirmation,
                                    .pairingCancellation, .pairingWithdrawal, .approvalClosed]
        return order.firstIndex { Int64($0.rawValue) == envelope.kind } ?? order.count
    }

    /// Applies the refusal rules of ADR 0013 → Sealed messages in order: the
    /// plaintext routing fields, the HPKE mode from the plaintext kind,
    /// decryption, the signed fields against the plaintext ones, the time
    /// rules, replay, the sender's signature, and the kind's binding. The
    /// message ID is reserved before the first suspension.
    private func processOne(_ envelope: DeviceEnvelope) async throws -> Outcome {
        let now = clock.now()
        let routing: MessageCodec.Routing
        do {
            routing = try MessageCodec.routing(of: envelope, ownID: deviceID, now: now)
        } catch {
            return .refused(error as? DeviceMessageRefusal ?? .malformed, authenticated: false)
        }
        let opened: (inner: InnerMessage, session: PairingSessionID?)
        do {
            guard let result = try open(envelope, routing: routing, now: now) else {
                return .refused(.noSession, authenticated: false)
            }
            opened = result
        } catch let refusal as DeviceMessageRefusal {
            return .refused(refusal, authenticated: false)
        }
        let inner = opened.inner
        guard !processed.contains(inner.messageID) else { return .refused(.replayed, authenticated: false) }
        guard inFlight.insert(inner.messageID).inserted else { return .busy }
        defer { inFlight.remove(inner.messageID) }
        let outcome = routing.kind.isPairing
            ? try await handlePairingMessage(inner, recordName: envelope.recordName, pskSession: opened.session, now: now)
            : try await handlePeerMessage(inner, envelope: envelope, now: now)
        switch outcome {
        case .processed, .refused(_, authenticated: true):
            processed.insert(inner.messageID, until: UnixTime.date(inner.expiresAt))
        case .refused, .held, .busy:
            break
        }
        return outcome
    }

    /// Opens a message. PSK-mode kinds need a session that can hold them: a
    /// request only the current initiator session, a withdrawal also a
    /// retired one. Returns nil when no session can, and which session's
    /// pre-shared key opened the message.
    private func open(_ envelope: DeviceEnvelope, routing: MessageCodec.Routing,
                      now: Date) throws -> (inner: InnerMessage, session: PairingSessionID?)? {
        guard routing.kind.usesPreSharedKey else {
            return (try MessageCodec.open(envelope, routing: routing, ownID: deviceID, identity: identity,
                                          preSharedKey: nil, now: now), nil)
        }
        var candidates = [session].compactMap { $0 }
        if routing.kind == .pairingWithdrawal { candidates += retiredSessions }
        candidates = candidates.filter { $0.role == .initiator && $0.isOpen(at: now) }
        for (index, candidate) in candidates.enumerated() {
            do {
                let inner = try MessageCodec.open(envelope, routing: routing, ownID: deviceID, identity: identity,
                                                  preSharedKey: candidate.qr.preSharedKey, now: now)
                return (inner, candidate.qr.sessionID)
            } catch DeviceMessageRefusal.decryptionFailed where index < candidates.count - 1 {
                continue
            }
        }
        return nil
    }

    /// Kinds 6–8 and 10–14 come from a device on the list. A message from the open
    /// session's peer that is not on the list yet, that is bound to the
    /// pairing this session is replacing, or that is an unpair notice, is
    /// held until the session ends, so a notice from before a removal and a
    /// new pairing cannot end the new pairing.
    private func handlePeerMessage(_ inner: InnerMessage, envelope: DeviceEnvelope, now: Date) async throws -> Outcome {
        let list = try await registry.list()
        let open = session.flatMap { $0.isOpen(at: now) && !$0.added ? $0 : nil }
        let fromSessionPeer = open?.peerID == inner.sender
        guard let entry = list.device(inner.sender) else {
            guard fromSessionPeer, let key = open?.peerMessageKey else {
                return .refused(.unknownSender, authenticated: false)
            }
            return inner.hasValidSignature(from: key) ? .held : .refused(.badSignature, authenticated: false)
        }
        guard inner.hasValidSignature(from: entry.card.messagePublicKey) else {
            return .refused(.badSignature, authenticated: false)
        }
        if fromSessionPeer, inner.kind == .unpairNotice { return .held }
        if inner.kind.isApproval {
            return try await applyApproval(inner, envelope: envelope, from: entry, holdingMismatch: fromSessionPeer)
        }
        let outcome = try await apply(inner, from: entry, now: now)
        if case .refused(.bindingMismatch, _) = outcome, fromSessionPeer { return .held }
        return outcome
    }

    private func apply(_ inner: InnerMessage, from entry: PairedDevice, now: Date) async throws -> Outcome {
        switch inner.kind {
        case .unpairNotice:
            guard let payload = try? PairingIDPayload(decoding: inner.payload) else {
                return .refused(.malformed, authenticated: true)
            }
            guard payload.pairingID == entry.pairingID else { return .refused(.bindingMismatch, authenticated: true) }
            let effects = endSessions(with: entry.deviceID)
            dropChecks(for: entry.deviceID)
            try await commit(.remove(entry.deviceID, pairingID: entry.pairingID))
            await perform(effects)
            return .processed
        case .deliveryCheck:
            guard let payload = try? PairingIDPayload(decoding: inner.payload) else {
                return .refused(.malformed, authenticated: true)
            }
            guard payload.pairingID == entry.pairingID else { return .refused(.bindingMismatch, authenticated: true) }
            let reply = DeliveryCheckReplyPayload(pairingID: entry.pairingID, checkMessageID: inner.messageID)
            let sealed = try seal(.deliveryCheckReply, reply.encoded, to: entry.card,
                                  lifetime: MessageKind.deliveryCheckLifetime, now: now)
            try await transport.send(sealed.envelope)
            try await registry.apply(.recordReached(entry.deviceID, pairingID: entry.pairingID, at: now))
            return .processed
        case .deliveryCheckReply:
            guard let payload = try? DeliveryCheckReplyPayload(decoding: inner.payload) else {
                return .refused(.malformed, authenticated: true)
            }
            guard payload.pairingID == entry.pairingID, let check = pendingChecks[payload.checkMessageID],
                  check.peer == entry.deviceID, check.pairingID == entry.pairingID, check.expiresAt > now else {
                return .refused(.bindingMismatch, authenticated: true)
            }
            try await registry.apply(.recordDeliveryCheck(entry.deviceID, pairingID: entry.pairingID,
                                                          result: .replied(at: now)))
            pendingChecks[payload.checkMessageID] = nil
            return .processed
        default:
            return .refused(.unexpectedKind, authenticated: true)
        }
    }
}
