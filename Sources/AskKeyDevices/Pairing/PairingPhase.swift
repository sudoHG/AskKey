import Foundation

/// What a pairing session shows the person.
public enum PairingPhase: Hashable, Sendable {
    /// Initiator: the QR code is shown and no request has been frozen yet.
    case showingQRCode(PairingQRPayload)
    /// Responder: the request is sent and no verified challenge has arrived.
    case waitingForChallenge
    /// Both sides: compare this code with the other device's. On the
    /// initiator nothing here reveals whether the responder has confirmed.
    case comparing(ComparisonCode, peer: PairingPeer)
    /// This side confirmed; the peer's verified confirmation has not arrived.
    case waitingForPeer(ComparisonCode, peer: PairingPeer)
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
    /// The person chose Codes Don't Match on this side.
    case codesDidNotMatch
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
    /// the request was withdrawn. Tell the person that pairing failed and
    /// not to confirm a code the Mac may show.
    case noChallenge
    case deviceLimitReached
    case keyConflict
    /// The person removed the peer while the session was open.
    case peerRemoved
    /// This device's identity no longer works.
    case identityUnusable
}
