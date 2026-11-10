import CryptoKit
import Foundation

public enum DeviceMessengerError: Error, Equatable, Sendable {
    /// No pairing session waits for this side's confirmation: none is open
    /// or it ended, it has no code yet (the initiator has no verified reveal,
    /// or the responder has not sent its reveal), or this side already confirmed.
    case notAwaitingConfirmation
    /// This side's approval prompt is still open; the call counts nothing.
    case confirmationInProgress
    /// Only the initiator enters a code.
    case wrongRole
    /// The initiator has no accepted code; it confirms only after
    /// `enterPairingCode` accepted one. Nothing was sent.
    case codeRequired
    /// The session already accepted a code and takes no further entry. It
    /// does not count as an attempt.
    case codeAlreadyAccepted
    /// The typed code is not six ASCII digits once white space is removed.
    /// It does not count as an attempt.
    case invalidCodeFormat
    /// The typed code did not match. At 0 the session ended and the peer
    /// was told.
    case wrongCode(attemptsRemaining: Int)
    /// The session ended while the person was confirming.
    case sessionEnded
    /// The list already holds 8 devices and the other device is not on it.
    case deviceLimitReached
    /// The other device's keys equal this device's own or another entry's.
    case keyConflict
    /// The device is not on the paired-device list.
    case unknownDevice
}

/// What became of one fetched message in a poll (ADR 0013 → Change tokens).
public enum InboxMessageOutcome: Hashable, Sendable {
    /// Its effect is committed; it was deleted.
    case processed
    /// Refused for good; it was deleted.
    case refused(DeviceMessageRefusal)
    /// Kept for a retry within an open pairing session, such as a
    /// confirmation that arrived before the reveal. Not a failure; it is
    /// refused and deleted once the session ends.
    case keptForSession
    /// It failed to process and will be fetched again; the third failure
    /// refuses it.
    case failed
}

/// A summary of one inbox poll, without message content.
public struct InboxReport: Hashable, Sendable {
    /// Messages whose effect is committed; they were deleted.
    public var processed = 0
    /// Early messages from a pairing session's peer, kept for a retry.
    public var held = 0
    /// Messages that failed to process and will be fetched again.
    public var failed = 0
    /// Refused messages, which were deleted. Log them without content.
    public var refusals: [DeviceMessageRefusal] = []
    /// Each fetched message's last outcome in this poll, by record name.
    public var outcomes: [String: InboxMessageOutcome] = [:]

    public init() {}
}

/// One device's side of ADR 0013: it runs pairing sessions as initiator or
/// responder, seals and opens messages, applies every refusal rule, keeps
/// processed message IDs in memory until they expire, answers and tracks
/// delivery checks, sends and applies unpair notices, and commits list
/// changes through the registry. It stores nothing; the caller persists the
/// key blobs, the list (through its store) and `inboxToken`.
///
/// The App-level coordinator (#287) and the iPhone app (#289) wrap it with
/// their authentication, storage and polling schedule.
public actor DeviceMessenger {
    struct PendingCheck {
        let peer: DeviceID
        let pairingID: PairingID
        let sentAt: Date
        let expiresAt: Date
    }

    public nonisolated let deviceID: DeviceID
    public nonisolated let platform: DevicePlatform
    let identity: any DeviceIdentity
    let registry: PairedDeviceRegistry
    let transport: any DeviceTransport
    let clock: any DeviceClock

    var session: PairingSession?
    /// Changes whenever `session` is replaced, so work that awaited can tell.
    var sessionGeneration = 0
    /// Sessions that added their peer and were replaced before they expired.
    /// They take only cancellations and withdrawals, so each can still undo
    /// its result until its expiry.
    var retiredSessions: [PairingSession] = []
    var processed = ProcessedMessageIDs()
    var pendingChecks: [MessageID: PendingCheck] = [:]
    /// When each record was first fetched, for the 30-second freezing rule.
    var firstFetched: [String: Date] = [:]
    var failureCounts: [String: Int] = [:]
    var isPolling = false
    /// Whether the delivery checks an earlier run left pending were adopted.
    var adoptedStoredChecks = false
    /// The inbox change token after the last fully processed fetch.
    public internal(set) var inboxToken: InboxChangeToken?

    public init(identity: any DeviceIdentity, platform: DevicePlatform, registry: PairedDeviceRegistry,
                transport: any DeviceTransport, clock: any DeviceClock, inboxToken: InboxChangeToken? = nil) {
        self.identity = identity
        self.platform = platform
        self.registry = registry
        self.transport = transport
        self.clock = clock
        self.inboxToken = inboxToken
        deviceID = DeviceID(messagePublicKey: identity.messagePublicKey)
    }

    // MARK: Pairing

    /// The current or last session's phase, or nil before any session.
    public var pairingPhase: PairingPhase? { session?.phase }

    /// Initiator, step 1: ends any open session that has not added its peer,
    /// then starts a new one and returns the QR payload to show. Throws
    /// `DeviceIdentityError`.
    public func startPairing(displayName: String) async throws -> PairingQRPayload {
        let now = clock.now()
        let card = try DeviceCard.make(identity: identity, platform: platform, createdAt: now)
        let new = PairingSession.initiate(identity: identity, card: card, displayName: displayName, now: now)
        await endOpenSession()
        replaceSession(with: new)
        return new.qr
    }

    /// Responder, step 2: decodes the scanned text, refuses an expired or
    /// foreign code, and sends the pairing request. Throws
    /// `PairingQRPayloadError`, `DeviceMessengerError` or `DeviceIdentityError`.
    public func joinPairing(scannedText: String, displayName: String) async throws {
        let qr = try PairingQRPayload(text: scannedText)
        let list = try await registry.list()
        let now = clock.now()
        let card = try DeviceCard.make(identity: identity, platform: platform, createdAt: now)
        let new = try PairingSession.respond(to: qr, identity: identity, card: card, displayName: displayName,
                                             now: now, list: list)
        await endOpenSession()
        replaceSession(with: new)
        await flushOutbox()
    }

    /// Initiator, step 5: the person typed the code the responder shows.
    /// White space is removed; anything but six ASCII digits throws
    /// `invalidCodeFormat` at once, without counting; before a verified
    /// reveal there is no code, so any entry throws `notAwaitingConfirmation`
    /// without counting. A match accepts the
    /// entry: the phase becomes `codeAccepted`, the session takes no further
    /// entry (`codeAlreadyAccepted`), and the person confirms with
    /// `confirmPairing(approvalReason:)`. A wrong code throws `wrongCode`
    /// with the attempts left, and the third ends the session and tells the
    /// responder. Nothing here signs.
    public func enterPairingCode(_ text: String) async throws {
        guard let entered = EnteredPairingCode(text) else { throw DeviceMessengerError.invalidCodeFormat }
        _ = try await currentSessionAfterTimers()
        guard let check = try session?.acceptEnteredCode(entered, now: clock.now()) else {
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        if case .wrong(let remaining, let effects) = check {
            await perform(effects)
            throw DeviceMessengerError.wrongCode(attemptsRemaining: remaining)
        }
    }

    /// Step 5, both sides: signs this side's confirmation with the approval
    /// key and sends it. The responder confirms on the device that shows
    /// the code; on an iPhone the signature asks for Face ID or Touch ID.
    /// The initiator confirms only while its session is open and holds an
    /// accepted code, and otherwise throws `codeRequired` and sends
    /// nothing; the Mac's system authentication belongs inside the
    /// identity's `signWithApprovalKey`, which only this call reaches. A
    /// cancelled or failed prompt sends nothing and counts nothing, and the
    /// person may confirm again without typing the code again. The peer is
    /// added once its verified confirmation is also held.
    public func confirmPairing(approvalReason: String) async throws {
        let generation = try await currentSessionAfterTimers()
        guard let current = session else { throw DeviceMessengerError.notAwaitingConfirmation }
        guard !current.confirmationPending else { throw DeviceMessengerError.confirmationInProgress }
        guard current.awaitsConfirmation, current.isOpen(at: clock.now()) else {
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        guard current.role == .responder || current.codeAccepted else { throw DeviceMessengerError.codeRequired }
        try await signAndConfirm(approvalReason: approvalReason, generation: generation)
    }

    /// Applies the timers, then checks that the session the person saw is
    /// still current. Returns its generation.
    private func currentSessionAfterTimers() async throws -> Int {
        let generation = sessionGeneration
        await perform(session?.tick(now: clock.now()) ?? [])
        // Sending while the timers ran may have let another session replace it.
        guard generation == sessionGeneration else { throw DeviceMessengerError.sessionEnded }
        guard session != nil else { throw DeviceMessengerError.notAwaitingConfirmation }
        return generation
    }

    private func signAndConfirm(approvalReason: String, generation: Int) async throws {
        guard generation == sessionGeneration else { throw DeviceMessengerError.sessionEnded }
        guard let bytes = session?.beginConfirmation() else { throw DeviceMessengerError.notAwaitingConfirmation }
        do {
            try await sign(bytes, approvalReason: approvalReason, generation: generation)
        } catch {
            if generation == sessionGeneration { session?.abandonConfirmation() }
            throw error
        }
    }

    private func sign(_ bytes: Data, approvalReason: String, generation: Int) async throws {
        let signature: Data
        do {
            signature = try await identity.signWithApprovalKey(bytes, reason: approvalReason)
        } catch DeviceIdentityError.unusable {
            if generation == sessionGeneration { await perform(session?.cancel(.identityUnusable, now: clock.now()) ?? []) }
            throw DeviceIdentityError.unusable
        }
        // The prompt may have outlasted the session or seen it end.
        await perform(session?.tick(now: clock.now()) ?? [])
        guard generation == sessionGeneration, session?.confirmationBytes == bytes else {
            throw DeviceMessengerError.sessionEnded
        }
        let effects: [PairingEffect]
        do {
            effects = try session?.confirm(approvalSignature: signature, now: clock.now()) ?? []
        } catch DeviceIdentityError.unusable {
            await perform(session?.cancel(.identityUnusable, now: clock.now()) ?? [])
            throw DeviceIdentityError.unusable
        }
        await perform(effects)
    }

    /// Cancel, closing the pairing sheet, or locking management. It changes
    /// nothing once this side has added the peer.
    public func cancelPairing() async {
        await perform(session?.cancel(.cancelled, now: clock.now()) ?? [])
    }

    func endOpenSession() async {
        guard let session, session.isOpen(at: clock.now()) else { return }
        await perform(self.session?.cancel(.cancelled, now: clock.now()) ?? [])
    }

    func replaceSession(with new: PairingSession) {
        if let old = session, old.added, old.isOpen(at: clock.now()) {
            retiredSessions.append(old)
        }
        session = new
        sessionGeneration += 1
    }

    /// Ends every session with a peer the person removed or that removed
    /// this device, before any suspension, so that no session can add the
    /// peer back afterwards. Returns the effects that still need sending.
    func endSessions(with peer: DeviceID) -> [PairingEffect] {
        retiredSessions.removeAll { $0.peerID == peer }
        guard let current = session, current.peerID == peer, current.isOpen(at: clock.now()) else { return [] }
        let effects = session?.cancel(.peerRemoved, now: clock.now()) ?? []
        session?.close(.peerRemoved)
        return effects
    }

    // MARK: Timers

    /// Applies every time-dependent rule: session expiry, the responder's
    /// withdrawal 60 seconds after a request without a challenge, delivery
    /// checks that expired without a reply, resending queued session
    /// messages, and forgetting processed IDs whose messages expired.
    /// `poll()` calls it; a pairing sheet can also call it on a timer.
    public func advanceTimers() async {
        let now = clock.now()
        processed.prune(now: now)
        await adoptStoredChecks()
        retiredSessions.removeAll { !$0.isOpen(at: now) }
        await perform(session?.tick(now: now) ?? [])
        if session?.needsAdd == true { await perform([.addPeer]) }
        for (id, check) in pendingChecks where check.expiresAt <= now {
            pendingChecks[id] = nil
            _ = try? await registry.apply(.recordDeliveryCheck(check.peer, pairingID: check.pairingID,
                                                               result: .noReply(sentAt: check.sentAt)))
        }
    }

    /// A check recorded as pending by an earlier run cannot be answered in
    /// this one; it becomes unanswered when its lifetime ends.
    private func adoptStoredChecks() async {
        guard !adoptedStoredChecks, let list = try? await registry.list() else { return }
        adoptedStoredChecks = true
        for device in list.devices {
            guard case .pending(let sentAt) = device.lastDeliveryCheck,
                  !pendingChecks.values.contains(where: { $0.peer == device.deviceID && $0.sentAt == sentAt }) else { continue }
            pendingChecks[.random()] = PendingCheck(peer: device.deviceID, pairingID: device.pairingID, sentAt: sentAt,
                                                    expiresAt: sentAt.addingTimeInterval(MessageKind.deliveryCheckLifetime))
        }
    }

    // MARK: Effects

    /// Performs the current session's effects. An undo is performed by the
    /// inbox, which can report a failed removal.
    func perform(_ effects: [PairingEffect]) async {
        let generation = sessionGeneration
        for effect in effects {
            guard generation == sessionGeneration else { return }
            switch effect {
            case .send(let envelope):
                session?.outbox.append(envelope)
            case .addPeer:
                await addSessionPeer(generation: generation)
            case .undo:
                assertionFailure("undo effects are performed by the inbox")
            }
        }
        await flushOutbox()
    }

    private func addSessionPeer(generation: Int) async {
        let now = clock.now()
        guard let current = session, current.needsAdd, current.isOpen(at: now),
              let entry = current.entry(pairedAt: now) else { return }
        do {
            guard entry.card.compressedPublicKeys.isDisjoint(with: identity.compressedPublicKeys) else {
                throw PairedDeviceListError.keyConflict
            }
            try await registry.apply(.add(entry))
            // The session may have ended while the list was written, for
            // example by Cancel, a cancellation or a removal; then it stores nothing.
            guard generation == sessionGeneration, let current = session, current.isOpen(at: clock.now()) else {
                _ = try? await registry.apply(.remove(entry.deviceID, pairingID: entry.pairingID))
                return
            }
            session?.peerAdded()
        } catch let error as PairedDeviceListError {
            guard generation == sessionGeneration else { return }
            let reason: PairingEndReason = error == .limitReached ? .deviceLimitReached : .keyConflict
            let effects = session?.addFailed(reason, now: now) ?? []
            for case .send(let envelope) in effects { session?.outbox.append(envelope) }
        } catch {
            // The store failed; `advanceTimers()` tries again while the session is open.
        }
    }

    /// Sends each queued session message once. A message that fails stays
    /// queued and is resent with the same message ID; an expired one is dropped.
    func flushOutbox() async {
        let generation = sessionGeneration
        var attempted = Set<String>()
        while generation == sessionGeneration,
              let envelope = session?.outbox.first(where: { !attempted.contains($0.recordName) }) {
            attempted.insert(envelope.recordName)
            if envelope.expiresAt <= clock.now() {
                session?.outbox.removeAll { $0.recordName == envelope.recordName }
                continue
            }
            do {
                try await transport.send(envelope)
                if generation == sessionGeneration {
                    session?.outbox.removeAll { $0.recordName == envelope.recordName }
                    session?.messageSent(envelope.recordName)
                }
            } catch {
                continue
            }
        }
    }

    func dropChecks(for peer: DeviceID) {
        pendingChecks = pendingChecks.filter { $0.value.peer != peer }
    }
}

/// Processed message IDs, kept in memory until their messages expire.
struct ProcessedMessageIDs {
    private var expiries: [MessageID: Date] = [:]

    func contains(_ id: MessageID) -> Bool { expiries[id] != nil }

    mutating func insert(_ id: MessageID, until expiry: Date) {
        expiries[id] = max(expiries[id] ?? expiry, expiry)
    }

    mutating func prune(now: Date) {
        expiries = expiries.filter { $0.value > now }
    }
}
