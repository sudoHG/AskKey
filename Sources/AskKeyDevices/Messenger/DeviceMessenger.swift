import CryptoKit
import Foundation

public enum DeviceMessengerError: Error, Equatable, Sendable {
    /// No pairing session is comparing codes.
    case notComparing
    /// The session ended while the person was confirming.
    case sessionEnded
    /// The list already holds 8 devices and the other device is not on it.
    case deviceLimitReached
    /// The other device's keys equal this device's own or another entry's.
    case keyConflict
    /// The device is not on the paired-device list.
    case unknownDevice
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
    var processed = ProcessedMessageIDs()
    var pendingChecks: [MessageID: PendingCheck] = [:]
    /// When each record was first fetched, for the 30-second freezing rule.
    var firstFetched: [String: Date] = [:]
    var failureCounts: [String: Int] = [:]
    /// Undo removals whose store write failed; retried by `advanceTimers()`.
    var pendingRemovals: [DeviceID: PairingID] = [:]
    var isPolling = false
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

    /// Initiator, step 1: ends any open session, then starts a new one and
    /// returns the QR payload to show. Throws `DeviceIdentityError`.
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

    /// Step 5: the person compared the codes and confirms. Signs the
    /// confirmation with the approval key, which on an iPhone asks for Face ID
    /// or Touch ID; a cancelled prompt sends nothing. The peer is added once
    /// its verified confirmation is also held.
    public func confirmPairing(approvalReason: String) async throws {
        guard let bytes = session?.confirmationBytes else { throw DeviceMessengerError.notComparing }
        let generation = sessionGeneration
        let signature: Data
        do {
            signature = try await identity.signWithApprovalKey(bytes, reason: approvalReason)
        } catch DeviceIdentityError.unusable {
            if generation == sessionGeneration { await perform(session?.cancel(.identityUnusable, now: clock.now()) ?? []) }
            throw DeviceIdentityError.unusable
        }
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

    /// Codes Don't Match.
    public func rejectPairingCode() async {
        await perform(session?.cancel(.codesDidNotMatch, now: clock.now()) ?? [])
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
        session = new
        sessionGeneration += 1
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
        await perform(session?.tick(now: now) ?? [])
        if session?.needsAdd == true { await perform([.addPeer]) }
        for (id, pairingID) in pendingRemovals {
            await removeEntry(id, pairingID: pairingID)
        }
        for (id, check) in pendingChecks where check.expiresAt <= now {
            pendingChecks[id] = nil
            _ = try? await registry.apply(.recordDeliveryCheck(check.peer, pairingID: check.pairingID,
                                                               result: .noReply(sentAt: check.sentAt)))
        }
    }

    // MARK: Effects

    func perform(_ effects: [PairingEffect]) async {
        let generation = sessionGeneration
        for effect in effects {
            guard generation == sessionGeneration else { return }
            switch effect {
            case .send(let envelope):
                session?.outbox.append(envelope)
            case .addPeer:
                await addSessionPeer(generation: generation)
            case .removeEntry(let id, let pairingID):
                await removeEntry(id, pairingID: pairingID)
            }
        }
        await flushOutbox()
    }

    private func addSessionPeer(generation: Int) async {
        let now = clock.now()
        guard let current = session, current.needsAdd, let entry = current.entry(pairedAt: now) else { return }
        do {
            guard entry.card.compressedPublicKeys.isDisjoint(with: identity.compressedPublicKeys) else {
                throw PairedDeviceListError.keyConflict
            }
            try await registry.apply(.add(entry))
            // The session may have ended while the list was written, for
            // example by Cancel or a cancellation; then it stores nothing.
            guard generation == sessionGeneration, let current = session, current.endReason == nil else {
                await removeEntry(entry.deviceID, pairingID: entry.pairingID)
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
                }
            } catch {
                continue
            }
        }
    }

    private func removeEntry(_ id: DeviceID, pairingID: PairingID) async {
        dropChecks(for: id)
        do {
            try await registry.apply(.remove(id, pairingID: pairingID))
            pendingRemovals[id] = nil
        } catch {
            pendingRemovals[id] = pairingID
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
