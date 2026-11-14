import Foundation

/// A sealed message ready to send. Send these exact bytes again to retry;
/// sealing again would change the sent time, the signature and the digest.
public struct SealedDeviceMessage: Hashable, Sendable {
    public let envelope: DeviceEnvelope
    public let messageID: MessageID
    /// SHA-256 over the inner message's exact bytes, signature included; for
    /// an approval request, its request digest.
    public let digest: Data
}

/// An approval request as sealed for one approver.
public struct SealedApprovalRequest: Hashable, Sendable {
    public let sealed: SealedDeviceMessage
    /// What was sealed: the response ID, and the offers after shortening,
    /// which the App records in its outstanding entry.
    public let request: ApprovalRequest

    public var requestDigest: Data { sealed.digest }
}

/// Seals kind 10–14 messages and delivery check replies without any state,
/// for a recipient entry the caller holds: the messenger's current list, or
/// the card the Mac held before a removal for a closing message. Every
/// message uses base-mode HPKE; its sent time is this sealer's clock when it
/// seals, after any approval prompt.
public struct DeviceMessageSealer: Sendable {
    public let identity: any DeviceIdentity
    public let clock: any DeviceClock

    public init(identity: any DeviceIdentity, clock: any DeviceClock) {
        self.identity = identity
        self.clock = clock
    }

    /// Kind 10 with a new random response ID, built by
    /// `ApprovalRequest.build` (escaping, shortening, Deny only when
    /// shortened). Its transport expiry is the deadline plus 5 minutes, at
    /// most 10 minutes after sealing. Throws `ApprovalMessageError`, for
    /// example `deadlineOutOfRange` for a deadline that has passed or is
    /// more than 300 seconds away.
    public func sealApprovalRequest(_ display: ApprovalRequestDisplay, bindingDigest: Data, deadline: Date,
                                    launchTime: Date, offers: ApprovalOffers, timedDuration: UInt64,
                                    to recipient: PairedDevice) throws -> SealedApprovalRequest {
        let sentAt = UnixTime.seconds(clock.now())
        let deadlineSeconds = UnixTime.seconds(deadline)
        guard deadlineSeconds > sentAt, deadlineSeconds - sentAt <= ApprovalLayout.maximumDeadlineDelay else {
            throw ApprovalMessageError.deadlineOutOfRange
        }
        let request = try ApprovalRequest.build(display: display, pairingID: recipient.pairingID, responseID: .random(),
                                                bindingDigest: bindingDigest, deadline: deadlineSeconds,
                                                launchTime: UnixTime.seconds(launchTime), offers: offers,
                                                timedDuration: timedDuration)
        let sealed = try seal(.approvalRequest, request.encoded, to: recipient, sentAt: sentAt,
                              expiresAt: ApprovalRequest.expiry(sentAt: sentAt, deadline: deadlineSeconds))
        return SealedApprovalRequest(sealed: sealed, request: request)
    }

    /// Kind 11 for a verified request, with the request's response ID as its
    /// message ID. Allow Once and the timed allowance sign the decision
    /// statement with the approval key, which on an iPhone asks for Face ID
    /// or Touch ID; Deny carries a zero slot and asks for nothing. Throws
    /// `ApprovalMessageError.notOffered` for a code the request did not
    /// offer, and `DeviceIdentityError` from the prompt.
    public func sealApprovalDecision(_ code: ApprovalDecisionCode, answering request: VerifiedApprovalMessage,
                                     approvalReason: String) async throws -> SealedDeviceMessage {
        guard case .request(let content) = request.message else { throw ApprovalMessageError.notARequest }
        guard content.offers.contains(code) else { throw ApprovalMessageError.notOffered }
        let ceiling = code == .timedAllowance ? content.timedDuration : 0
        var slot = Data(count: ApprovalLayout.signatureByteCount)
        if code != .deny {
            let statement = ApprovalDecision.statement(approver: identity.deviceID, requester: request.senderID,
                                                       pairingID: request.pairingID, requestDigest: request.digest,
                                                       code: code, durationCeiling: ceiling)
            slot = try await identity.signWithApprovalKey(statement, reason: approvalReason)
            guard slot.count == ApprovalLayout.signatureByteCount else { throw DeviceIdentityError.authenticationFailed }
        }
        let payload = ApprovalDecision.encode(pairingID: request.pairingID, requestDigest: request.digest, code: code,
                                              durationCeiling: ceiling, slot: slot)
        let sentAt = UnixTime.seconds(clock.now())
        return try seal(.approvalDecision, payload, to: request.sender, sentAt: sentAt,
                        expiresAt: sentAt + Int64(MessageKind.approvalLifetime), messageID: content.responseID)
    }

    /// Kind 12 with a random message ID. Throws
    /// `ApprovalMessageError.invalidClosedOutcome` unless outcome 1 carries
    /// the applied code (and, for code 2, the granted seconds) and the other
    /// outcomes carry neither, and `invalidDigest` for a digest that is not
    /// 32 bytes.
    public func sealApprovalClosed(_ outcome: ApprovalClosedOutcome, appliedCode: ApprovalDecisionCode? = nil,
                                   appliedDuration: UInt64 = 0, requestDigest: Data,
                                   to recipient: PairedDevice) throws -> SealedDeviceMessage {
        guard requestDigest.count == ApprovalLayout.digestByteCount else { throw ApprovalMessageError.invalidDigest }
        guard ApprovalClosed.isConsistent(outcome: outcome, code: appliedCode, duration: appliedDuration) else {
            throw ApprovalMessageError.invalidClosedOutcome
        }
        let payload = ApprovalClosed.encode(pairingID: recipient.pairingID, requestDigest: requestDigest,
                                            outcome: outcome, appliedCode: appliedCode, appliedDuration: appliedDuration)
        return try sealApprovalKind(.approvalClosed, payload, to: recipient)
    }

    /// Kind 13 for a verified request, with the receipt ID as its message ID.
    public func sealApprovalReceipt(answering request: VerifiedApprovalMessage) throws -> SealedDeviceMessage {
        guard case .request(let content) = request.message else { throw ApprovalMessageError.notARequest }
        let payload = ApprovalReceipt.encode(pairingID: request.pairingID, requestDigest: request.digest)
        return try sealApprovalKind(.approvalReceipt, payload, to: request.sender,
                                    messageID: ApprovalReceipt.receiptID(for: content.responseID))
    }

    /// Kind 14 to the Mac `mac`: the code proof for the typed code, signed
    /// with the approval key over the confirmation statement, which asks for
    /// Face ID or Touch ID. Throws `DeviceIdentityError` from the prompt.
    public func sealApproverConfirmation(_ code: ApproverCode, to mac: PairedDevice,
                                         approvalReason: String) async throws -> SealedDeviceMessage {
        let phone = identity.deviceID
        let proof = code.proof(mac: mac.deviceID, phone: phone, pairingID: mac.pairingID)
        let statement = ApproverConfirmation.statement(phone: phone, mac: mac.deviceID, pairingID: mac.pairingID,
                                                       codeProof: proof)
        let signature = try await identity.signWithApprovalKey(statement, reason: approvalReason)
        guard signature.count == ApprovalLayout.signatureByteCount else { throw DeviceIdentityError.authenticationFailed }
        let payload = ApproverConfirmation.encode(pairingID: mac.pairingID, codeProof: proof, signature: signature)
        return try sealApprovalKind(.approverConfirmation, payload, to: mac)
    }

    /// Kind 8 for a verified delivery check, signed with the message key, as
    /// the notification extension answers on a locked phone.
    public func sealDeliveryCheckReply(answering check: VerifiedDeliveryCheck) throws -> SealedDeviceMessage {
        let payload = DeliveryCheckReplyPayload(pairingID: check.sender.pairingID, checkMessageID: check.messageID)
        let sentAt = UnixTime.seconds(clock.now())
        return try seal(.deliveryCheckReply, payload.encoded, to: check.sender, sentAt: sentAt,
                        expiresAt: sentAt + Int64(MessageKind.deliveryCheckLifetime))
    }

    private func sealApprovalKind(_ kind: MessageKind, _ payload: Data, to recipient: PairedDevice,
                                  messageID: MessageID = .random()) throws -> SealedDeviceMessage {
        let sentAt = UnixTime.seconds(clock.now())
        return try seal(kind, payload, to: recipient, sentAt: sentAt, expiresAt: sentAt + Int64(MessageKind.approvalLifetime),
                        messageID: messageID)
    }

    private func seal(_ kind: MessageKind, _ payload: Data, to recipient: PairedDevice, sentAt: Int64, expiresAt: Int64,
                      messageID: MessageID = .random()) throws -> SealedDeviceMessage {
        let sealed = try MessageCodec.seal(kind: kind, payload: payload, identity: identity, recipient: recipient.deviceID,
                                           recipientKey: recipient.card.agreementPublicKey, preSharedKey: nil,
                                           sentAt: sentAt, expiresAt: expiresAt, messageID: messageID)
        return SealedDeviceMessage(envelope: sealed.envelope, messageID: sealed.inner.messageID, digest: sealed.inner.digest)
    }
}
