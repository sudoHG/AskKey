import CryptoKit
import Foundation

/// What a session asks its owner to do.
enum PairingEffect {
    /// Queue a sealed session message; it is resent with the same message ID
    /// until it is delivered or expires.
    case send(DeviceEnvelope)
    /// Both confirmations are held: add `entry(pairedAt:)` to the list.
    case addPeer
    /// Undo this session's result: remove the entry if it still has this
    /// session's pairing ID, then `close(.undoneByPeer)`. An entry the
    /// pairing replaced is not restored.
    case undo(DeviceID, PairingID)
}

enum PairingOutcome {
    case accepted([PairingEffect])
    /// `authenticated` tells whether the sender's signature verified, so the
    /// message ID may be recorded as processed.
    case refused(DeviceMessageRefusal, authenticated: Bool)
    /// An early message from the session's peer; retry it until the session ends.
    case held
}

/// The pairing state machine of ADR 0013 → Pairing, for both roles. It
/// performs no I/O: it seals messages and returns effects for its owner.
///
/// The person confirms as decided in #282, decision 5: the responder shows
/// the code and the person types it on the initiator, which never exposes
/// it. The initiator checks the typed code before it lets the approval key
/// sign; a wrong code counts as an attempt, and the third ends the session.
/// The responder confirms without typing.
struct PairingSession {
    static let qrLifetime: TimeInterval = 5 * 60
    /// A session ends 5 minutes after the QR expiry, so at most 10 minutes.
    static let sessionExtension: TimeInterval = 5 * 60
    static let lateFetchAllowance: TimeInterval = 30
    static let challengeTimeout: TimeInterval = 60
    /// Wrong codes the initiator accepts in one session; the last ends it.
    static let maximumCodeAttempts = 3

    struct Peer {
        let card: DeviceCard
        let displayName: String
    }

    let role: PairingRole
    let qr: PairingQRPayload
    let expiry: Date
    private let identity: any DeviceIdentity
    let ownCard: DeviceCard
    private let ownDisplayName: String

    /// Initiator: the message ID of the frozen request.
    private(set) var frozenRequestID: MessageID?
    /// Responder: the digest of its own request and when it was first sent.
    private var requestDigest: Data?
    private var requestSentAt: Date?

    private(set) var peer: Peer?
    private(set) var transcriptHash: Data?
    /// Never shown on the initiator; there it only checks the typed code.
    private(set) var code: PairingCode?
    private(set) var pairingID: PairingID?
    /// Initiator: wrong codes typed in this session.
    private var wrongCodeAttempts = 0
    /// Initiator: the code typed for the confirmation in progress matched.
    /// Cleared when that confirmation fails, so each signature needs its
    /// own matching code. Never set on the responder.
    private var codeVerified = false
    /// An approval prompt for this side's confirmation is open; further
    /// confirmations are refused until it ends, without counting.
    private(set) var confirmationPending = false
    private(set) var localConfirmed = false
    private(set) var peerConfirmed = false
    private(set) var added = false
    private(set) var endReason: PairingEndReason?
    var outbox: [DeviceEnvelope] = []

    private init(role: PairingRole, qr: PairingQRPayload, identity: any DeviceIdentity, ownCard: DeviceCard,
                 displayName: String) {
        self.role = role
        self.qr = qr
        expiry = qr.qrExpiry.addingTimeInterval(Self.sessionExtension)
        self.identity = identity
        self.ownCard = ownCard
        ownDisplayName = DeviceDisplayName.clean(displayName)
    }

    /// Step 1: a new session with a random session ID and pairing secret, a
    /// QR expiry 5 minutes ahead and a session expiry 5 minutes after that.
    static func initiate(identity: any DeviceIdentity, card: DeviceCard, displayName: String, now: Date) -> PairingSession {
        let qr = PairingQRPayload(sessionID: .random(), secret: RandomBytes.make(32),
                                  qrExpiry: UnixTime.date(UnixTime.seconds(now)).addingTimeInterval(qrLifetime),
                                  initiatorMessageKey: identity.messagePublicKey,
                                  initiatorAgreementKey: identity.agreementPublicKey)
        return PairingSession(role: .initiator, qr: qr, identity: identity, ownCard: card, displayName: displayName)
    }

    /// Step 2: refuses an expired code, sets the session expiry to the QR
    /// expiry plus 5 minutes, and queues the PSK-mode request.
    static func respond(to qr: PairingQRPayload, identity: any DeviceIdentity, card: DeviceCard, displayName: String,
                        now: Date, list: PairedDeviceList) throws -> PairingSession {
        guard now < qr.qrExpiry else { throw PairingQRPayloadError.expired }
        let initiatorKeys: Set<Data> = [qr.initiatorMessageKey.compressedRepresentation,
                                        qr.initiatorAgreementKey.compressedRepresentation]
        guard initiatorKeys.isDisjoint(with: identity.compressedPublicKeys),
              !list.devices.contains(where: { $0.deviceID != qr.initiatorID && !$0.card.compressedPublicKeys.isDisjoint(with: initiatorKeys) }) else {
            throw DeviceMessengerError.keyConflict
        }
        guard list.devices.count < PairedDeviceList.maximumCount || list.device(qr.initiatorID) != nil else {
            throw DeviceMessengerError.deviceLimitReached
        }
        var session = PairingSession(role: .responder, qr: qr, identity: identity, ownCard: card, displayName: displayName)
        let payload = PairingRequestPayload(sessionID: qr.sessionID, card: card, displayName: session.ownDisplayName)
        guard let sealed = try session.seal(.pairingRequest, payload.encoded, to: qr.initiatorID,
                                            key: qr.initiatorAgreementKey, now: now) else {
            throw PairingQRPayloadError.expired
        }
        session.requestDigest = sealed.inner.digest
        session.requestSentAt = now
        session.outbox = [sealed.envelope]
        return session
    }

    // MARK: State

    func isOpen(at now: Date) -> Bool { endReason == nil && now < expiry }

    /// The device whose session messages this side accepts.
    var peerID: DeviceID? {
        role == .responder ? qr.initiatorID : peer?.card.deviceID
    }

    /// The key that signs the peer's messages. The responder knows the
    /// initiator's from the QR code before any challenge.
    var peerMessageKey: P256.Signing.PublicKey? {
        role == .responder ? qr.initiatorMessageKey : peer?.card.messagePublicKey
    }

    /// Both confirmations are held but the peer is not on the list yet.
    var needsAdd: Bool { endReason == nil && localConfirmed && peerConfirmed && !added }

    var phase: PairingPhase {
        if let endReason { return .ended(endReason) }
        let summary = peer.map { PairingPeer(deviceID: $0.card.deviceID, platform: $0.card.platform,
                                             displayName: $0.displayName) }
        if added, let summary, let pairingID { return .paired(peer: summary, pairingID: pairingID) }
        if let code, let summary {
            switch role {
            case .initiator:
                return localConfirmed ? .waitingForPeer(peer: summary)
                    : .enteringCode(peer: summary, attemptsRemaining: Self.maximumCodeAttempts - wrongCodeAttempts)
            case .responder:
                return .showingCode(code, peer: summary, confirmed: localConfirmed)
            }
        }
        return role == .initiator ? .showingQRCode(qr) : .waitingForChallenge
    }

    func entry(pairedAt: Date) -> PairedDevice? {
        guard let peer, let pairingID else { return nil }
        return PairedDevice(card: peer.card, pairingID: pairingID, displayName: peer.displayName, pairedAt: pairedAt)
    }

    // MARK: Incoming messages

    /// Initiator, kind 1. The PSK opened, so the sender read the QR code.
    /// Freezes the first fully verified request fetched by 30 seconds after
    /// the QR expiry; a second one ends the session.
    mutating func handleRequest(_ inner: InnerMessage, firstFetchedAt: Date, now: Date,
                                list: PairedDeviceList) throws -> PairingOutcome {
        guard role == .initiator else { return .refused(.unexpectedKind, authenticated: false) }
        let payload: PairingRequestPayload
        do { payload = try PairingRequestPayload(decoding: inner.payload) } catch {
            return .refused(Self.refusal(error), authenticated: false)
        }
        guard payload.card.deviceID == inner.sender else { return .refused(.routingMismatch, authenticated: false) }
        guard inner.hasValidSignature(from: payload.card.messagePublicKey) else {
            return .refused(.badSignature, authenticated: false)
        }
        guard payload.sessionID == qr.sessionID else { return .refused(.bindingMismatch, authenticated: true) }
        if frozenRequestID != nil {
            guard !added else { return .refused(.bindingMismatch, authenticated: true) }
            return .accepted(end(.secondRequest, now: now))
        }
        guard firstFetchedAt <= qr.qrExpiry.addingTimeInterval(Self.lateFetchAllowance) else {
            return .refused(.requestTooLate, authenticated: true)
        }
        guard !conflicts(payload.card, list: list) else { return .refused(.keyConflict, authenticated: true) }
        frozenRequestID = inner.messageID
        peer = Peer(card: payload.card, displayName: payload.displayName)
        if list.devices.count >= PairedDeviceList.maximumCount, list.device(payload.card.deviceID) == nil {
            return .accepted(end(.deviceLimitReached, now: now))
        }
        let nonce = RandomBytes.make(32)
        derive(responderCard: payload.card, initiatorCard: ownCard, nonce: nonce)
        let challenge = PairingChallengePayload(sessionID: qr.sessionID, requestDigest: inner.digest, card: ownCard,
                                                nonce: nonce, displayName: ownDisplayName)
        guard let sealed = try seal(.pairingChallenge, challenge.encoded, to: payload.card.deviceID,
                                    key: payload.card.agreementPublicKey, now: now) else { return .accepted([]) }
        return .accepted([.send(sealed.envelope)])
    }

    /// Initiator, kind 5: accepted from any device that read the QR code.
    mutating func handleWithdrawal(_ inner: InnerMessage, now: Date) -> PairingOutcome {
        guard role == .initiator else { return .refused(.unexpectedKind, authenticated: false) }
        let payload: PairingWithdrawalPayload
        do { payload = try PairingWithdrawalPayload(decoding: inner.payload) } catch {
            return .refused(Self.refusal(error), authenticated: false)
        }
        guard payload.card.deviceID == inner.sender else { return .refused(.routingMismatch, authenticated: false) }
        guard inner.hasValidSignature(from: payload.card.messagePublicKey) else {
            return .refused(.badSignature, authenticated: false)
        }
        guard payload.sessionID == qr.sessionID else { return .refused(.bindingMismatch, authenticated: true) }
        return .accepted(endByPeer(sender: inner.sender, now: now))
    }

    /// Kinds 2, 3 and 4, which only the session's peer may send.
    mutating func handlePeerMessage(_ inner: InnerMessage, now: Date, list: PairedDeviceList) throws -> PairingOutcome {
        guard let peerID, inner.sender == peerID, let key = peerMessageKey else {
            return .refused(.unknownSender, authenticated: false)
        }
        guard inner.hasValidSignature(from: key) else { return .refused(.badSignature, authenticated: false) }
        switch inner.kind {
        case .pairingChallenge: return try handleChallenge(inner, now: now, list: list)
        case .pairingConfirmation: return handleConfirmation(inner)
        case .pairingCancellation:
            do {
                guard try PairingCancellationPayload(decoding: inner.payload).sessionID == qr.sessionID else {
                    return .refused(.bindingMismatch, authenticated: true)
                }
            } catch {
                return .refused(Self.refusal(error), authenticated: true)
            }
            return .accepted(endByPeer(sender: inner.sender, now: now))
        default:
            return .refused(.unexpectedKind, authenticated: true)
        }
    }

    /// Responder, step 3: checks the challenge against its own request and
    /// the keys in the QR code, then computes the code.
    private mutating func handleChallenge(_ inner: InnerMessage, now: Date, list: PairedDeviceList) throws -> PairingOutcome {
        guard role == .responder else { return .refused(.unexpectedKind, authenticated: true) }
        let payload: PairingChallengePayload
        do { payload = try PairingChallengePayload(decoding: inner.payload) } catch {
            return .refused(Self.refusal(error), authenticated: true)
        }
        guard transcriptHash == nil, payload.sessionID == qr.sessionID, let requestDigest,
              payload.requestDigest == requestDigest,
              payload.card.messagePublicKey.compressedRepresentation == qr.initiatorMessageKey.compressedRepresentation,
              payload.card.agreementPublicKey.compressedRepresentation == qr.initiatorAgreementKey.compressedRepresentation else {
            return .refused(.bindingMismatch, authenticated: true)
        }
        guard !conflicts(payload.card, list: list) else { return .refused(.keyConflict, authenticated: true) }
        peer = Peer(card: payload.card, displayName: payload.displayName)
        if list.devices.count >= PairedDeviceList.maximumCount, list.device(payload.card.deviceID) == nil {
            return .accepted(end(.deviceLimitReached, now: now))
        }
        derive(responderCard: ownCard, initiatorCard: payload.card, nonce: payload.nonce)
        return .accepted([])
    }

    /// Step 5: the peer's confirmation, signed by its approval key over its
    /// role, its device ID and the transcript hash.
    private mutating func handleConfirmation(_ inner: InnerMessage) -> PairingOutcome {
        guard let transcriptHash, let peer else { return .held }
        let payload: PairingConfirmationPayload
        do { payload = try PairingConfirmationPayload(decoding: inner.payload) } catch {
            return .refused(Self.refusal(error), authenticated: true)
        }
        guard payload.role == role.other, payload.signer == inner.sender, payload.transcriptHash == transcriptHash,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: payload.signature),
              peer.card.approvalPublicKey.isValidSignature(signature, for: DomainLabel.pairingConfirmation + payload.signedFields) else {
            return .refused(.bindingMismatch, authenticated: true)
        }
        guard !peerConfirmed else { return .accepted([]) }
        peerConfirmed = true
        return .accepted(addEffects())
    }

    // MARK: The person's actions

    /// The code is derived and this side has not confirmed or ended.
    var awaitsConfirmation: Bool {
        endReason == nil && !localConfirmed && transcriptHash != nil && code != nil
    }

    enum CodeCheck {
        case matched
        /// At 0 attempts remaining the session ended and `effects` tell the peer.
        case wrong(attemptsRemaining: Int, effects: [PairingEffect])
    }

    /// Initiator: checks the code the person typed, in constant time. A
    /// match lets the approval key sign; a wrong code counts as one attempt,
    /// and the third ends the session with a cancellation to the peer.
    mutating func checkEnteredCode(_ entered: EnteredPairingCode, now: Date) throws -> CodeCheck {
        guard role == .initiator else { throw DeviceMessengerError.wrongRole }
        guard !confirmationPending else { throw DeviceMessengerError.confirmationInProgress }
        guard awaitsConfirmation, let code else { throw DeviceMessengerError.notAwaitingConfirmation }
        guard isOpen(at: now) else { throw DeviceMessengerError.sessionEnded }
        if code.matches(entered) {
            codeVerified = true
            return .matched
        }
        wrongCodeAttempts += 1
        let remaining = Self.maximumCodeAttempts - wrongCodeAttempts
        return .wrong(attemptsRemaining: remaining, effects: remaining > 0 ? [] : end(.codeMismatch, now: now))
    }

    /// The bytes the approval key signs when the person confirms, or nil if
    /// this side cannot confirm now. The initiator needs the matching code first.
    var confirmationBytes: Data? {
        guard awaitsConfirmation, role == .responder || codeVerified, let transcriptHash else { return nil }
        return PairingConfirmationPayload.signedBytes(role: role, signer: ownCard.deviceID, transcriptHash: transcriptHash)
    }

    /// Starts this side's confirmation: returns the bytes to sign and
    /// refuses further confirmations until it is confirmed or abandoned.
    mutating func beginConfirmation() -> Data? {
        guard !confirmationPending, let bytes = confirmationBytes else { return nil }
        confirmationPending = true
        return bytes
    }

    /// The approval prompt failed or the session moved on: the next
    /// confirmation starts over, and an initiator needs the code again.
    mutating func abandonConfirmation() {
        confirmationPending = false
        codeVerified = false
    }

    /// The person confirmed; `signature` is the approval key's signature
    /// over `confirmationBytes`.
    mutating func confirm(approvalSignature: Data, now: Date) throws -> [PairingEffect] {
        guard let transcriptHash, let peer, confirmationBytes != nil else {
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        guard isOpen(at: now) else { throw DeviceMessengerError.sessionEnded }
        localConfirmed = true
        confirmationPending = false
        let payload = PairingConfirmationPayload.encode(role: role, signer: ownCard.deviceID,
                                                        transcriptHash: transcriptHash, signature: approvalSignature)
        var effects: [PairingEffect] = []
        if let sealed = try seal(.pairingConfirmation, payload, to: peer.card.deviceID,
                                 key: peer.card.agreementPublicKey, now: now) {
            effects.append(.send(sealed.envelope))
        }
        return effects + addEffects()
    }

    /// Cancel, or a reason from the owner. Before this
    /// side added the peer it ends the session with nothing stored and tells
    /// the peer it knows; afterwards it changes nothing.
    mutating func cancel(_ reason: PairingEndReason, now: Date) -> [PairingEffect] {
        guard endReason == nil, !added else { return [] }
        return end(reason, now: now)
    }

    /// Ends the session whatever its state, without telling the peer, for
    /// example when the person removed the peer.
    mutating func close(_ reason: PairingEndReason) {
        if endReason == nil { endReason = reason }
        outbox.removeAll()
    }

    mutating func peerAdded() { added = true }

    mutating func addFailed(_ reason: PairingEndReason, now: Date) -> [PairingEffect] { end(reason, now: now) }

    /// Expiry, and the responder's withdrawal 60 seconds after its request
    /// when no challenge has arrived.
    mutating func tick(now: Date) -> [PairingEffect] {
        guard endReason == nil, !added else { return [] }
        if now >= expiry {
            // A cancellation now would already be expired; the peer's session ends at the same time.
            endReason = .expired
            outbox.removeAll()
            return []
        }
        if role == .responder, peer == nil, let requestSentAt,
           now >= requestSentAt.addingTimeInterval(Self.challengeTimeout) {
            return end(.noChallenge, now: now)
        }
        return []
    }

    // MARK: Helpers

    private mutating func derive(responderCard: DeviceCard, initiatorCard: DeviceCard, nonce: Data) {
        let hash = PairingDerivation.transcriptHash(qrPayload: qr.bytes, responderCard: responderCard.bytes,
                                                    initiatorCard: initiatorCard.bytes, nonce: nonce)
        transcriptHash = hash
        code = PairingDerivation.comparisonCode(secret: qr.secret, transcriptHash: hash)
        pairingID = PairingDerivation.pairingID(transcriptHash: hash)
    }

    private func addEffects() -> [PairingEffect] {
        needsAdd ? [.addPeer] : []
    }

    /// A cancellation or withdrawal for this session: before this side added
    /// the peer it ends the session; afterwards it asks its owner to undo the
    /// result, and stays open until the entry is removed.
    private mutating func endByPeer(sender: DeviceID, now: Date) -> [PairingEffect] {
        if added {
            guard let peer, let pairingID else { return [] }
            return [.undo(peer.card.deviceID, pairingID)]
        }
        return end(.cancelledByPeer, now: now, tellPeer: sender != peerID)
    }

    /// Ends the session before the peer was added. A responder without a
    /// challenge sends a PSK-mode withdrawal; otherwise the side sends a
    /// cancellation to the peer it knows.
    private mutating func end(_ reason: PairingEndReason, now: Date, tellPeer: Bool = true) -> [PairingEffect] {
        guard endReason == nil else { return [] }
        endReason = reason
        outbox.removeAll()
        guard tellPeer else { return [] }
        let sealed: MessageCodec.Sealed?
        if role == .responder, peer == nil {
            let payload = PairingWithdrawalPayload(sessionID: qr.sessionID, card: ownCard)
            sealed = try? seal(.pairingWithdrawal, payload.encoded, to: qr.initiatorID, key: qr.initiatorAgreementKey, now: now)
        } else if let peer {
            let payload = PairingCancellationPayload(sessionID: qr.sessionID)
            sealed = try? seal(.pairingCancellation, payload.encoded, to: peer.card.deviceID,
                               key: peer.card.agreementPublicKey, now: now)
        } else {
            sealed = nil
        }
        return sealed.map { [.send($0.envelope)] } ?? []
    }

    /// Cards whose keys equal this device's own or another entry's are refused.
    private func conflicts(_ card: DeviceCard, list: PairedDeviceList) -> Bool {
        !card.compressedPublicKeys.isDisjoint(with: identity.compressedPublicKeys)
            || list.devices.contains { $0.deviceID != card.deviceID && !$0.card.compressedPublicKeys.isDisjoint(with: card.compressedPublicKeys) }
    }

    /// Seals a session message that expires with the session, and never
    /// lives longer than a pairing message may. Nil once the session expired.
    private func seal(_ kind: MessageKind, _ payload: Data, to recipient: DeviceID, key: P256.KeyAgreement.PublicKey,
                      now: Date) throws -> MessageCodec.Sealed? {
        let sentAt = UnixTime.seconds(now)
        let expiresAt = min(UnixTime.seconds(expiry), sentAt + Int64(MessageKind.pairingLifetime))
        guard expiresAt > sentAt else { return nil }
        return try MessageCodec.seal(kind: kind, payload: payload, identity: identity, recipient: recipient,
                                     recipientKey: key, preSharedKey: kind.usesPreSharedKey ? qr.preSharedKey : nil,
                                     sentAt: sentAt, expiresAt: expiresAt)
    }

    private static func refusal(_ error: Error) -> DeviceMessageRefusal {
        error as? DeviceMessageRefusal ?? .malformed
    }
}
