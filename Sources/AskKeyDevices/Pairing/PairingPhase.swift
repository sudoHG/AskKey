import Foundation

/// What a pairing session shows the person.
public enum PairingPhase: Hashable, Sendable {
    /// Initiator: the QR code is shown and no request has been frozen yet.
    case showingQRCode(PairingQRPayload)
    /// Responder: the request is sent and no verified challenge has arrived.
    case waitingForChallenge
    /// Initiator: ask the person to type the code the responder shows.
    /// The initiator never exposes the code. Nothing here reveals whether
    /// the responder has confirmed.
    case enteringCode(peer: PairingPeer, attemptsRemaining: Int)
    /// Initiator: the typed code matched and was accepted; no further entry
    /// is taken. Confirm with system authentication, again after a
    /// cancelled or failed one, without typing the code again.
    case codeAccepted(peer: PairingPeer)
    /// Initiator: this side confirmed; the responder's verified confirmation
    /// has not arrived.
    case waitingForPeer(peer: PairingPeer)
    /// Responder: show this code, which the person types on the Mac, and
    /// ask the person to confirm on this device. `confirmed` tells whether
    /// this side has confirmed; the code stays on screen until the session
    /// ends or the peer is added, because the Mac may still need it.
    case showingCode(PairingCode, peer: PairingPeer, confirmed: Bool)
    /// Both confirmations are held and the peer is on the list.
    case paired(peer: PairingPeer, pairingID: PairingID)
    case ended(PairingEndReason)
}

/// The other device of a session, as it describes itself.
public struct PairingPeer: Hashable, Sendable {
    public let deviceID: DeviceID
    /// Self-declared; never presented as verified.
    public let platform: DevicePlatform
    /// The proposed display name, cleaned.
    public let displayName: String

    public init(deviceID: DeviceID, platform: DevicePlatform, displayName: String) {
        self.deviceID = deviceID
        self.platform = platform
        self.displayName = DeviceDisplayName.clean(displayName)
    }
}

public enum PairingEndReason: Hashable, Sendable {
    /// The person chose Cancel on this side.
    case cancelled
    /// Initiator: the person typed a code that did not match three times.
    case codeMismatch
    /// A cancellation or withdrawal for this session arrived before this
    /// side added the peer.
    case cancelledByPeer
    /// A cancellation or withdrawal for this session arrived after this side
    /// added the peer; the entry this session wrote was removed.
    case undoneByPeer
    /// Initiator: a second verified request arrived for this session.
    case secondRequest
    case expired
    /// Responder: no challenge arrived within 60 seconds of the request, so
    /// the request was withdrawn. Tell the person that pairing failed, that
    /// they should cancel on the Mac, and not to enter any code there.
    case noChallenge
    case deviceLimitReached
    case keyConflict
    /// The person removed the peer while the session was open.
    case peerRemoved
    /// This device's identity no longer works.
    case identityUnusable
}
