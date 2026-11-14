import CryptoKit
import Foundation

/// The content of a verified kind 10–14 message.
public enum ApprovalMessage: Hashable, Sendable {
    case request(ApprovalRequest)
    case decision(ApprovalDecision)
    case closed(ApprovalClosed)
    case receipt(ApprovalReceipt)
    case confirmation(ApproverConfirmation)
}

/// A kind 10–14 message that passed every rule `AskKeyDevices` checks:
/// ADR 0013's refusal rules, the payload layout, the pairing ID against the
/// sender's current entry, and the approval-key signature of decisions and
/// confirmations (ADR 0014 → Verifying and applying a decision, checks 1, 3
/// and 6). The App checks the rest against its own state.
public struct VerifiedApprovalMessage: Hashable, Sendable {
    /// The sender's entry on this device's list when the message was verified.
    public let sender: PairedDevice
    /// For a decision, the request's response ID; for a receipt, the receipt ID.
    public let messageID: MessageID
    /// The signed times, on the sender's clock.
    public let sentAt: Date
    public let expiresAt: Date
    /// SHA-256 over the inner message's exact bytes, signature included; for
    /// an approval request, its request digest.
    public let digest: Data
    /// The envelope as fetched, which holds only ciphertext; the stateless
    /// verifier opens it again.
    public let envelope: DeviceEnvelope
    public let message: ApprovalMessage

    public var senderID: DeviceID { sender.deviceID }
    /// The pairing ID the payload carries, which is the sender's current one.
    public var pairingID: PairingID { sender.pairingID }
}

/// What the caller's handler made of a verified approval message.
public enum ApprovalMessageHandling: Hashable, Sendable {
    /// Its effect is committed; the message is deleted.
    case processed
    /// Refused without effect; the message is deleted and a re-inserted copy
    /// is refused as replayed.
    case refused(DeviceMessageRefusal)
    /// It failed; the message stays and is handled again, and the third
    /// failure refuses it.
    case failed
}

/// Handles verified kind 10–14 messages for the App; it runs inside the
/// messenger's serialized handling, once per message ID at a time.
public typealias ApprovalMessageHandler = @Sendable (VerifiedApprovalMessage) async -> ApprovalMessageHandling

enum ApprovalVerification {
    /// The checks of a kind 10–14 message whose sender is `entry` and whose
    /// message-key signature already verified: the payload layout
    /// (`malformed`), the pairing ID against the entry (`bindingMismatch`),
    /// a request's times against its inner message's, and the approval-key
    /// signature of an Allow or a confirmation over the statement rebuilt
    /// from the signed fields (`badSignature`).
    static func verify(_ inner: InnerMessage, from entry: PairedDevice) -> Result<ApprovalMessage, DeviceMessageRefusal> {
        let message: ApprovalMessage
        let pairingID: PairingID
        do {
            switch inner.kind {
            case .approvalRequest:
                let request = try ApprovalRequest(decoding: inner.payload)
                (message, pairingID) = (.request(request), request.pairingID)
            case .approvalDecision:
                let decision = try ApprovalDecision(decoding: inner.payload)
                (message, pairingID) = (.decision(decision), decision.pairingID)
            case .approvalClosed:
                let closed = try ApprovalClosed(decoding: inner.payload)
                (message, pairingID) = (.closed(closed), closed.pairingID)
            case .approvalReceipt:
                let receipt = try ApprovalReceipt(decoding: inner.payload)
                (message, pairingID) = (.receipt(receipt), receipt.pairingID)
            case .approverConfirmation:
                let confirmation = try ApproverConfirmation(decoding: inner.payload)
                (message, pairingID) = (.confirmation(confirmation), confirmation.pairingID)
            default:
                return .failure(.unexpectedKind)
            }
        } catch {
            return .failure(.malformed)
        }
        guard pairingID == entry.pairingID else { return .failure(.bindingMismatch) }
        switch message {
        case .request(let request):
            if let refusal = request.checkTimes(sentAt: inner.sentAt, expiresAt: inner.expiresAt) { return .failure(refusal) }
        case .decision(let decision):
            if let signature = decision.approvalSignature {
                let statement = ApprovalDecision.statement(approver: inner.sender, requester: inner.recipient,
                                                           pairingID: decision.pairingID,
                                                           requestDigest: decision.requestDigest, code: decision.code,
                                                           durationCeiling: decision.durationCeiling)
                guard isValid(signature, over: statement, by: entry.card.approvalPublicKey) else {
                    return .failure(.badSignature)
                }
            }
        case .confirmation(let confirmation):
            let statement = ApproverConfirmation.statement(phone: inner.sender, mac: inner.recipient,
                                                           pairingID: confirmation.pairingID,
                                                           codeProof: confirmation.codeProof)
            guard isValid(confirmation.signature, over: statement, by: entry.card.approvalPublicKey) else {
                return .failure(.badSignature)
            }
        case .closed, .receipt:
            break
        }
        return .success(message)
    }

    static func verified(_ message: ApprovalMessage, inner: InnerMessage, envelope: DeviceEnvelope,
                         from entry: PairedDevice) -> VerifiedApprovalMessage {
        VerifiedApprovalMessage(sender: entry, messageID: inner.messageID, sentAt: UnixTime.date(inner.sentAt),
                                expiresAt: UnixTime.date(inner.expiresAt), digest: inner.digest, envelope: envelope,
                                message: message)
    }

    private static func isValid(_ signature: Data, over statement: Data, by key: P256.Signing.PublicKey) -> Bool {
        guard let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(parsed, for: statement)
    }
}
