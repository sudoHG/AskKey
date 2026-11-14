import Foundation

/// A delivery check that passed every refusal rule but replay.
public struct VerifiedDeliveryCheck: Hashable, Sendable {
    /// The sender's entry on this device's list when the check was verified.
    public let sender: PairedDevice
    public let messageID: MessageID
    public let envelope: DeviceEnvelope
}

/// What the stateless verifier found.
public enum DeviceMessageVerdict: Hashable, Sendable {
    case approval(VerifiedApprovalMessage)
    case deliveryCheck(VerifiedDeliveryCheck)
    case refused(DeviceMessageRefusal)
}

/// Verifies one envelope without any state (ADR 0014 → Notification Service
/// Extension): against the list it is given, it applies the same envelope,
/// signature, payload, pairing-ID and approval-signature checks as
/// `DeviceMessenger`, in the same order, for delivery checks and kinds
/// 10–14. It does not check replay, does not hold a message from an open
/// pairing session's peer as the messenger does, and does not know the
/// caller's handler or state: `.approval` means only that the checks
/// `AskKeyDevices` owns passed. It deletes nothing, writes nothing and never
/// uses the approval key. Pairing kinds need a session and are refused as
/// `noSession`; unpair notices and delivery check replies need the
/// messenger's state and are refused as `unexpectedKind`.
public struct DeviceMessageVerifier: Sendable {
    public let identity: any DeviceIdentity
    public let list: PairedDeviceList

    public init(identity: any DeviceIdentity, list: PairedDeviceList) {
        self.identity = identity
        self.list = list
    }

    /// Throws only `DeviceIdentityError`, when this device's own key no longer works.
    public func verify(_ envelope: DeviceEnvelope, now: Date) throws -> DeviceMessageVerdict {
        let ownID = identity.deviceID
        let routing: MessageCodec.Routing
        do {
            routing = try MessageCodec.routing(of: envelope, ownID: ownID, now: now)
        } catch {
            return .refused(error as? DeviceMessageRefusal ?? .malformed)
        }
        guard !routing.kind.isPairing else { return .refused(.noSession) }
        let inner: InnerMessage
        do {
            inner = try MessageCodec.open(envelope, routing: routing, ownID: ownID, identity: identity, preSharedKey: nil,
                                          now: now)
        } catch let refusal as DeviceMessageRefusal {
            return .refused(refusal)
        }
        guard let entry = list.device(inner.sender) else { return .refused(.unknownSender) }
        guard inner.hasValidSignature(from: entry.card.messagePublicKey) else { return .refused(.badSignature) }
        if inner.kind == .deliveryCheck {
            guard let payload = try? PairingIDPayload(decoding: inner.payload) else { return .refused(.malformed) }
            guard payload.pairingID == entry.pairingID else { return .refused(.bindingMismatch) }
            return .deliveryCheck(VerifiedDeliveryCheck(sender: entry, messageID: inner.messageID, envelope: envelope))
        }
        guard inner.kind.isApproval else { return .refused(.unexpectedKind) }
        switch ApprovalVerification.verify(inner, from: entry) {
        case .success(let message):
            return .approval(ApprovalVerification.verified(message, inner: inner, envelope: envelope, from: entry))
        case .failure(let refusal):
            return .refused(refusal)
        }
    }
}
