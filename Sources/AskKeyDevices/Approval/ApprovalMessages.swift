import CryptoKit
import Foundation

/// Kind 11, the approver's decision, 122 bytes for every code:
///
///     pairing ID (16) ‖ layout version (1) ‖ request digest (32) ‖ decision code (1)
///     ‖ duration ceiling (8) ‖ approval-signature slot (64)
///
/// For codes 1 and 2 the slot holds the approval key's raw ECDSA signature
/// over the decision statement; for code 0 it is 64 zero bytes, so Allow
/// and Deny have the same length. The message ID is the request's response ID.
public struct ApprovalDecision: Hashable, Sendable {
    public static let byteCount = 122

    public let pairingID: PairingID
    public let requestDigest: Data
    public let code: ApprovalDecisionCode
    /// 0 for codes 0 and 1; the offered timed duration for code 2.
    public let durationCeiling: UInt64
    /// The approval-key signature; nil for Deny.
    public let approvalSignature: Data?

    /// `AskKey approval decision v1\0` ‖ approver's device ID ‖ requester's
    /// device ID ‖ pairing ID ‖ request digest ‖ decision code ‖ duration
    /// ceiling. The approver is the decision's sender, the requester its
    /// recipient.
    public static func statement(approver: DeviceID, requester: DeviceID, pairingID: PairingID, requestDigest: Data,
                                 code: ApprovalDecisionCode, durationCeiling: UInt64) -> Data {
        var writer = ByteWriter()
        writer.append(DomainLabel.approvalDecision)
        writer.append(approver.rawValue)
        writer.append(requester.rawValue)
        writer.append(pairingID.rawValue)
        writer.append(requestDigest)
        writer.append(code.rawValue)
        writer.appendUInt64(durationCeiling)
        return writer.data
    }

    static func encode(pairingID: PairingID, requestDigest: Data, code: ApprovalDecisionCode, durationCeiling: UInt64,
                       slot: Data) -> Data {
        var writer = ByteWriter()
        ApprovalLayout.writeHeader(pairingID, into: &writer)
        writer.append(requestDigest)
        writer.append(code.rawValue)
        writer.appendUInt64(durationCeiling)
        writer.append(slot)
        return writer.data
    }

    /// Refuses as malformed a reserved code, a ceiling that is not 0 for
    /// codes 0 and 1 or is 0 for code 2, and a Deny whose slot is not all
    /// zeros. An Allow's signature is checked against the sender's key later.
    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            let pairingID = try ApprovalLayout.readHeader(&reader)
            let digest = try ApprovalLayout.readDigest(&reader)
            guard let code = ApprovalDecisionCode(rawValue: try reader.readByte()) else { throw MalformedEncoding() }
            let ceiling = try reader.readUInt64()
            let slot = try reader.readBytes(ApprovalLayout.signatureByteCount)
            switch code {
            case .deny:
                guard ceiling == 0, ApprovalLayout.isZero(slot) else { throw MalformedEncoding() }
            case .allowOnce:
                guard ceiling == 0 else { throw MalformedEncoding() }
            case .timedAllowance:
                guard ceiling != 0 else { throw MalformedEncoding() }
            }
            return ApprovalDecision(pairingID: pairingID, requestDigest: digest, code: code, durationCeiling: ceiling,
                                    approvalSignature: code == .deny ? nil : slot)
        }
    }

    private init(pairingID: PairingID, requestDigest: Data, code: ApprovalDecisionCode, durationCeiling: UInt64,
                 approvalSignature: Data?) {
        self.pairingID = pairingID
        self.requestDigest = requestDigest
        self.code = code
        self.durationCeiling = durationCeiling
        self.approvalSignature = approvalSignature
    }
}

/// Kind 12, how a request ended for one approver, 59 bytes:
///
///     pairing ID (16) ‖ layout version (1) ‖ request digest (32) ‖ outcome (1)
///     ‖ applied code (1) ‖ applied duration (8)
public struct ApprovalClosed: Hashable, Sendable {
    public static let byteCount = 59

    public let pairingID: PairingID
    public let requestDigest: Data
    public let outcome: ApprovalClosedOutcome
    /// The applied decision code for outcome 1; nil for the others.
    public let appliedCode: ApprovalDecisionCode?
    /// For outcome 1 with code 2, the seconds the Broker granted; else 0.
    public let appliedDuration: UInt64

    /// Whether the code and duration fit the outcome: for outcomes 2–6 both
    /// are 0; for outcome 1 the duration is 0 unless the code is 2.
    static func isConsistent(outcome: ApprovalClosedOutcome, code: ApprovalDecisionCode?, duration: UInt64) -> Bool {
        guard outcome == .applied else { return code == nil && duration == 0 }
        guard let code else { return false }
        return code == .timedAllowance || duration == 0
    }

    static func encode(pairingID: PairingID, requestDigest: Data, outcome: ApprovalClosedOutcome,
                       appliedCode: ApprovalDecisionCode?, appliedDuration: UInt64) -> Data {
        var writer = ByteWriter()
        ApprovalLayout.writeHeader(pairingID, into: &writer)
        writer.append(requestDigest)
        writer.append(outcome.rawValue)
        writer.append(appliedCode?.rawValue ?? 0)
        writer.appendUInt64(appliedDuration)
        return writer.data
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            let pairingID = try ApprovalLayout.readHeader(&reader)
            let digest = try ApprovalLayout.readDigest(&reader)
            guard let outcome = ApprovalClosedOutcome(rawValue: try reader.readByte()) else { throw MalformedEncoding() }
            let codeByte = try reader.readByte()
            let duration = try reader.readUInt64()
            let code: ApprovalDecisionCode?
            if outcome == .applied {
                guard let applied = ApprovalDecisionCode(rawValue: codeByte) else { throw MalformedEncoding() }
                code = applied
            } else {
                guard codeByte == 0 else { throw MalformedEncoding() }
                code = nil
            }
            guard Self.isConsistent(outcome: outcome, code: code, duration: duration) else { throw MalformedEncoding() }
            return ApprovalClosed(pairingID: pairingID, requestDigest: digest, outcome: outcome, appliedCode: code,
                                  appliedDuration: duration)
        }
    }

    private init(pairingID: PairingID, requestDigest: Data, outcome: ApprovalClosedOutcome,
                 appliedCode: ApprovalDecisionCode?, appliedDuration: UInt64) {
        self.pairingID = pairingID
        self.requestDigest = requestDigest
        self.outcome = outcome
        self.appliedCode = appliedCode
        self.appliedDuration = appliedDuration
    }
}

/// Kind 13, the approver's receipt for a request it showed, 49 bytes:
/// pairing ID (16) ‖ layout version (1) ‖ request digest (32). Its message
/// ID is the receipt ID.
public struct ApprovalReceipt: Hashable, Sendable {
    public static let byteCount = 49

    public let pairingID: PairingID
    public let requestDigest: Data

    /// The first 16 bytes of SHA-256 over `AskKey approval receipt id v1\0`
    /// and the response ID.
    public static func receiptID(for responseID: MessageID) -> MessageID {
        let digest = SHA256.hash(data: DomainLabel.approvalReceiptID + responseID.rawValue)
        return MessageID(rawValue: Data(digest.prefix(MessageID.byteCount)))!
    }

    static func encode(pairingID: PairingID, requestDigest: Data) -> Data {
        var writer = ByteWriter()
        ApprovalLayout.writeHeader(pairingID, into: &writer)
        writer.append(requestDigest)
        return writer.data
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            ApprovalReceipt(pairingID: try ApprovalLayout.readHeader(&reader),
                            requestDigest: try ApprovalLayout.readDigest(&reader))
        }
    }

    private init(pairingID: PairingID, requestDigest: Data) {
        self.pairingID = pairingID
        self.requestDigest = requestDigest
    }
}

/// Kind 14, the iPhone's approver confirmation, 113 bytes:
///
///     pairing ID (16) ‖ layout version (1) ‖ code proof (32)
///     ‖ approval-key signature (64) over the confirmation statement
public struct ApproverConfirmation: Hashable, Sendable {
    public static let byteCount = 113

    public let pairingID: PairingID
    /// The App compares it in constant time with its own (`ApproverCode`).
    public let codeProof: Data
    let signature: Data

    /// `AskKey approver confirmation v1\0` ‖ iPhone's device ID ‖ Mac's
    /// device ID ‖ pairing ID ‖ code proof.
    public static func statement(phone: DeviceID, mac: DeviceID, pairingID: PairingID, codeProof: Data) -> Data {
        var writer = ByteWriter()
        writer.append(DomainLabel.approverConfirmation)
        writer.append(phone.rawValue)
        writer.append(mac.rawValue)
        writer.append(pairingID.rawValue)
        writer.append(codeProof)
        return writer.data
    }

    static func encode(pairingID: PairingID, codeProof: Data, signature: Data) -> Data {
        var writer = ByteWriter()
        ApprovalLayout.writeHeader(pairingID, into: &writer)
        writer.append(codeProof)
        writer.append(signature)
        return writer.data
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            ApproverConfirmation(pairingID: try ApprovalLayout.readHeader(&reader),
                                 codeProof: try ApprovalLayout.readDigest(&reader),
                                 signature: try reader.readBytes(ApprovalLayout.signatureByteCount))
        }
    }

    private init(pairingID: PairingID, codeProof: Data, signature: Data) {
        self.pairingID = pairingID
        self.codeProof = codeProof
        self.signature = signature
    }
}

/// The binding digest (ADR 0014 → Encodings): SHA-256 over
/// `AskKey approval binding v1\0` and eight length-prefixed UTF-8 strings,
/// exactly as the Broker holds them, with no case folding or normalization.
public enum ApprovalBinding {
    /// `BrokerLimits.maximumFieldBytes`.
    public static let maximumFieldBytes = 4_096

    /// An absent optional digest is the empty string. Throws
    /// `ApprovalMessageError.invalidDigest` for a string over 4 KiB.
    public static func digest(requestID: String, operationID: String, credentialID: String, targetID: String,
                              operation: String, payloadDigest: String?, readProjectionDigest: String?,
                              retransmissionDigest: String?) throws -> Data {
        let strings = [requestID, operationID, credentialID, targetID, operation, payloadDigest ?? "",
                       readProjectionDigest ?? "", retransmissionDigest ?? ""]
        var writer = ByteWriter()
        writer.append(DomainLabel.approvalBinding)
        for string in strings {
            let bytes = Data(string.utf8)
            guard bytes.count <= maximumFieldBytes else { throw ApprovalMessageError.invalidDigest }
            writer.appendLengthPrefixed(bytes)
        }
        return Data(SHA256.hash(data: writer.data))
    }
}
