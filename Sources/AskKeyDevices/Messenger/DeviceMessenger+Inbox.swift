import Foundation

extension DeviceMessenger {
    enum Outcome {
        case processed
        /// `authenticated` tells whether the sender's signature verified.
        case refused(DeviceMessageRefusal, authenticated: Bool)
        case held
    }

    static let failureLimit = 3

    /// Fetches the inbox since `inboxToken` and processes every message.
    /// Processed and refused messages are deleted. The token advances only
    /// when every message of a fetch was processed or refused; a held or
    /// failed message keeps the old token, so the next poll fetches it again,
    /// and a message that fails three times is refused. An expired token
    /// leads to one full fetch from no token. A poll that starts while
    /// another is running returns an empty report. Throws
    /// `DeviceIdentityError` when this device's own key no longer works, and
    /// transport errors.
    public func poll() async throws -> InboxReport {
        guard !isPolling else { return InboxReport() }
        isPolling = true
        defer { isPolling = false }
        await advanceTimers()
        var report = InboxReport()
        var token = inboxToken
        var restarted = false
        while true {
            let changes: InboxChanges
            do {
                changes = try await transport.fetchInboxChanges(of: deviceID, since: token)
            } catch DeviceTransportError.changeTokenExpired where !restarted {
                token = nil
                restarted = true
                continue
            }
            guard try await process(changes, into: &report) else { break }
            token = changes.newToken
            inboxToken = token
            guard changes.moreComing else { break }
        }
        await advanceTimers()
        return report
    }

    /// Processes one fetch and deletes what settled. Pairing messages go
    /// first, in kind order; held messages are retried within the fetch
    /// after any message took effect. True when every message settled.
    private func process(_ changes: InboxChanges, into report: inout InboxReport) async throws -> Bool {
        let fetchedAt = clock.now()
        for envelope in changes.envelopes where firstFetched[envelope.recordName] == nil {
            firstFetched[envelope.recordName] = fetchedAt
        }
        var deletable = changes.malformedRecordNames
        report.refusals += changes.malformedRecordNames.map { _ in DeviceMessageRefusal.malformed }
        var pending = changes.envelopes.enumerated()
            .sorted { (Self.rank($0.element), $0.offset) < (Self.rank($1.element), $1.offset) }
            .map(\.element)
        var settled = true
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
                        settled = false
                        continue
                    }
                    outcome = .refused(.repeatedFailure, authenticated: false)
                }
                switch outcome {
                case .processed:
                    report.processed += 1
                    deletable.append(envelope.recordName)
                    progressed = true
                case .refused(let refusal, _):
                    report.refusals.append(refusal)
                    deletable.append(envelope.recordName)
                case .held:
                    held.append(envelope)
                }
            }
            pending = held
        }
        report.held += pending.count
        if !pending.isEmpty { settled = false }
        for name in deletable {
            firstFetched[name] = nil
            failureCounts[name] = nil
        }
        if !deletable.isEmpty {
            try await transport.deleteMessages(deletable, from: deviceID)
        }
        return settled
    }

    private static func rank(_ envelope: DeviceEnvelope) -> Int64 {
        (1...5).contains(envelope.kind) ? envelope.kind : 100
    }

    /// Applies the refusal rules of ADR 0013 → Sealed messages in order: the
    /// plaintext routing fields, the HPKE mode from the plaintext kind,
    /// decryption, the signed fields against the plaintext ones, the time
    /// rules, replay, the sender's signature, and the kind's binding.
    private func processOne(_ envelope: DeviceEnvelope) async throws -> Outcome {
        let now = clock.now()
        let routing: MessageCodec.Routing
        do {
            routing = try MessageCodec.routing(of: envelope, ownID: deviceID, now: now)
        } catch {
            return .refused(error as? DeviceMessageRefusal ?? .malformed, authenticated: false)
        }
        var preSharedKey: HPKEPreSharedKey?
        if routing.kind.usesPreSharedKey {
            guard let session, session.role == .initiator, session.isOpen(at: now) else {
                return .refused(.noSession, authenticated: false)
            }
            preSharedKey = session.qr.preSharedKey
        }
        let inner: InnerMessage
        do {
            inner = try MessageCodec.open(envelope, routing: routing, ownID: deviceID, identity: identity,
                                          preSharedKey: preSharedKey, now: now)
        } catch let refusal as DeviceMessageRefusal {
            return .refused(refusal, authenticated: false)
        }
        guard !processed.contains(inner.messageID) else { return .refused(.replayed, authenticated: false) }
        let outcome = routing.kind.isPairing
            ? try await handlePairingMessage(inner, recordName: envelope.recordName, now: now)
            : try await handlePeerMessage(inner, now: now)
        switch outcome {
        case .processed, .refused(_, authenticated: true):
            processed.insert(inner.messageID, until: UnixTime.date(inner.expiresAt))
        case .refused, .held:
            break
        }
        return outcome
    }

    /// Kinds 1–5 belong to the open session, which verifies the sender.
    private func handlePairingMessage(_ inner: InnerMessage, recordName: String, now: Date) async throws -> Outcome {
        let list = try await registry.list()
        guard session?.isOpen(at: now) == true else { return .refused(.noSession, authenticated: false) }
        let outcome: PairingOutcome
        do {
            switch inner.kind {
            case .pairingRequest:
                outcome = try session!.handleRequest(inner, firstFetchedAt: firstFetched[recordName] ?? now,
                                                     now: now, list: list)
            case .pairingWithdrawal:
                outcome = session!.handleWithdrawal(inner, now: now)
            default:
                outcome = try session!.handlePeerMessage(inner, now: now, list: list)
            }
        } catch DeviceIdentityError.unusable {
            session?.close(.identityUnusable)
            throw DeviceIdentityError.unusable
        }
        switch outcome {
        case .accepted(let effects):
            await perform(effects)
            return .processed
        case .refused(let refusal, let authenticated):
            return .refused(refusal, authenticated: authenticated)
        case .held:
            return .held
        }
    }

    /// Kinds 6–8 come from a device on the list. A message from the open
    /// session's peer that is not on the list yet, or that is bound to the
    /// pairing this session is replacing, is held until the session ends.
    private func handlePeerMessage(_ inner: InnerMessage, now: Date) async throws -> Outcome {
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
            try await registry.apply(.remove(entry.deviceID, pairingID: entry.pairingID))
            await endActivities(with: entry.deviceID)
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
