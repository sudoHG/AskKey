@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Every refusal rule for kinds 10–14, each refused without effect and
/// deleted, and the stateless verifier's verdict for the same envelope
/// (#310 acceptance 3 and 5).
final class ApprovalRefusalTests: XCTestCase {
    private var fixture: ApprovalFixture!
    private var request: SealedApprovalRequest!

    override func setUp() async throws {
        fixture = try await ApprovalFixture.make()
        request = try await fixture.sendRequest(offers: .all, timedDuration: 1_800)
        try await fixture.phone.poll()
    }

    private var now: Int64 { UnixTime.seconds(fixture.harness.clock.now()) }

    private func assertRefused(_ envelope: DeviceEnvelope, at device: SimulatedDevice, _ refusal: DeviceMessageRefusal,
                               reachesHandler: Bool = false, file: StaticString = #filePath,
                               line: UInt = #line) async throws {
        try await fixture.assertRefused(envelope, at: device, refusal, reachesHandler: reachesHandler, file: file, line: line)
    }

    /// A decision payload from the phone, signed as given.
    private func decisionPayload(code: ApprovalDecisionCode, ceiling: UInt64? = nil, pairingID: PairingID? = nil,
                                 digest: Data? = nil, slot: Data? = nil) async throws -> Data {
        var pairing = try await fixture.phoneEntryForMac().pairingID
        if let pairingID { pairing = pairingID }
        let digest = digest ?? request.requestDigest
        let ceiling = ceiling ?? (code == .timedAllowance ? 1_800 : 0)
        var signature = slot ?? Data(count: 64)
        if slot == nil, code != .deny {
            let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                       pairingID: pairing, requestDigest: digest, code: code,
                                                       durationCeiling: ceiling)
            signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        }
        return ApprovalDecision.encode(pairingID: pairing, requestDigest: digest, code: code, durationCeiling: ceiling,
                                       slot: signature)
    }

    private func decisionEnvelope(_ payload: Data, messageID: MessageID? = nil) throws -> DeviceEnvelope {
        try ApprovalFixture.seal(.approvalDecision, payload, from: fixture.phone, to: fixture.mac,
                                 messageID: messageID ?? request.request.responseID, sentAt: now)
    }

    private func statementSignature(approver: DeviceID, requester: DeviceID, pairingID: PairingID,
                                    code: ApprovalDecisionCode = .allowOnce, key: P256.Signing.PrivateKey) throws -> Data {
        let statement = ApprovalDecision.statement(approver: approver, requester: requester, pairingID: pairingID,
                                                   requestDigest: request.requestDigest, code: code, durationCeiling: 0)
        return try key.signature(for: statement).rawRepresentation
    }

    /// The refusal left the outstanding entry as it was: it is still there,
    /// and the genuine decision applies to it. A refused message signed with
    /// the phone's message key keeps its message ID as processed, so a
    /// genuine decision under the same response ID needs a messenger without
    /// that memory; the outstanding table here outlives it on purpose.
    private func assertEntryUnchanged(file: StaticString = #filePath, line: UInt = #line) async throws {
        let entry = try XCTUnwrap(fixture.outstanding.entry(request.request.responseID), file: file, line: line)
        XCTAssertEqual(entry.digest, request.requestDigest, file: file, line: line)
        XCTAssertTrue(fixture.outstanding.applied.isEmpty, file: file, line: line)
        fixture.mac.restart()
        let genuine = try await fixture.phone.messenger.sealer.sealApprovalDecision(.allowOnce,
                                                                                   answering: try fixture.phoneRequest(),
                                                                                   approvalReason: "Allow")
        try await fixture.harness.transport.send(genuine.envelope)
        await XCTAssertEqualAsync(try await fixture.mac.poll().processed, 1, file: file, line: line)
        XCTAssertEqual(fixture.outstanding.applied.count, 1, file: file, line: line)
    }

    // MARK: Checks 1, 3 and 6 in AskKeyDevices

    func testDecisionWithAnotherPairingIDIsRefused() async throws {
        let payload = try await decisionPayload(code: .allowOnce, pairingID: PairingID(rawValue: RandomBytes.make(16))!)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .bindingMismatch)
        try await assertEntryUnchanged()
    }

    func testAllowSignedOnlyWithTheMessageKeyIsRefused() async throws {
        let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                   pairingID: try await fixture.phoneEntryForMac().pairingID,
                                                   requestDigest: request.requestDigest, code: .allowOnce, durationCeiling: 0)
        let messageKeySignature = try fixture.phone.identity.signWithMessageKey(statement)
        let payload = try await decisionPayload(code: .allowOnce, slot: messageKeySignature)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testAllowSignedWithAnotherDevicesApprovalKeyIsRefused() async throws {
        let other = P256.Signing.PrivateKey()
        let signature = try statementSignature(approver: fixture.phone.id, requester: fixture.mac.id,
                                               pairingID: try await fixture.phoneEntryForMac().pairingID, key: other)
        let payload = try await decisionPayload(code: .allowOnce, slot: signature)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testAllowWhoseStatementNamesAnotherRequesterIsRefused() async throws {
        let otherMac = SoftwareDeviceIdentity().deviceID
        let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: otherMac,
                                                   pairingID: try await fixture.phoneEntryForMac().pairingID,
                                                   requestDigest: request.requestDigest, code: .allowOnce, durationCeiling: 0)
        let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        let payload = try await decisionPayload(code: .allowOnce, slot: signature)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testAllowWhoseStatementNamesAnotherPairingIDIsRefused() async throws {
        let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                   pairingID: PairingID(rawValue: RandomBytes.make(16))!,
                                                   requestDigest: request.requestDigest, code: .allowOnce, durationCeiling: 0)
        let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        let payload = try await decisionPayload(code: .allowOnce, slot: signature)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testAllowWhoseStatementSwapsApproverAndRequesterIsRefused() async throws {
        let statement = ApprovalDecision.statement(approver: fixture.mac.id, requester: fixture.phone.id,
                                                   pairingID: try await fixture.phoneEntryForMac().pairingID,
                                                   requestDigest: request.requestDigest, code: .allowOnce, durationCeiling: 0)
        let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        try await assertRefused(try decisionEnvelope(try await decisionPayload(code: .allowOnce, slot: signature)),
                                at: fixture.mac, .badSignature)
    }

    func testTimedAllowanceSignedForAnotherCeilingIsRefused() async throws {
        let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                   pairingID: try await fixture.phoneEntryForMac().pairingID,
                                                   requestDigest: request.requestDigest, code: .timedAllowance,
                                                   durationCeiling: 60)
        let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        let payload = try await decisionPayload(code: .timedAllowance, ceiling: 1_800, slot: signature)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testAnApprovalSignatureMovedToAnotherCodeOrDigestIsRefused() async throws {
        let pairingID = try await fixture.phoneEntryForMac().pairingID
        let onceStatement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                       pairingID: pairingID, requestDigest: request.requestDigest,
                                                       code: .allowOnce, durationCeiling: 0)
        let once = try await fixture.phone.identity.signWithApprovalKey(onceStatement, reason: "test")
        let asTimed = try await decisionPayload(code: .timedAllowance, slot: once)
        try await assertRefused(try decisionEnvelope(asTimed), at: fixture.mac, .badSignature)
        let otherDigest = Data(SHA256.hash(data: Data("another request".utf8)))
        let moved = try await decisionPayload(code: .allowOnce, digest: otherDigest, slot: once)
        try await assertRefused(try decisionEnvelope(moved, messageID: .random()), at: fixture.mac, .badSignature)
        try await assertEntryUnchanged()
    }

    func testDenyWithANonZeroSlotIsRefused() async throws {
        var slot = Data(count: 64)
        slot[63] = 1
        let payload = try await decisionPayload(code: .deny, slot: slot)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .malformed)
        try await assertEntryUnchanged()
    }

    // MARK: Checks 2, 4 and 5 reach the handler

    func testDecisionWhoseMessageIDIsNotTheResponseIDReachesTheHandlerAndIsRefused() async throws {
        let payload = try await decisionPayload(code: .allowOnce)
        try await assertRefused(try decisionEnvelope(payload, messageID: .random()), at: fixture.mac, .bindingMismatch,
                                reachesHandler: true)
        try await assertEntryUnchanged()
    }

    func testDecisionForAnotherRequestDigestReachesTheHandlerAndIsRefused() async throws {
        let payload = try await decisionPayload(code: .allowOnce, digest: Data(SHA256.hash(data: Data("other".utf8))))
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .bindingMismatch, reachesHandler: true)
        try await assertEntryUnchanged()
    }

    func testDecisionWithACodeOrCeilingNotOfferedReachesTheHandlerAndIsRefused() async throws {
        let payload = try await decisionPayload(code: .timedAllowance, ceiling: 3_600)
        try await assertRefused(try decisionEnvelope(payload), at: fixture.mac, .bindingMismatch, reachesHandler: true)
        let denyOnly = try await fixture.sendRequest(offers: .denyOnly)
        let notOffered = try await decisionPayload(code: .allowOnce, digest: denyOnly.requestDigest)
        let envelope = try ApprovalFixture.seal(.approvalDecision, notOffered, from: fixture.phone, to: fixture.mac,
                                                messageID: denyOnly.request.responseID, sentAt: now)
        try await assertRefused(envelope, at: fixture.mac, .bindingMismatch, reachesHandler: true)
        XCTAssertNotNil(fixture.outstanding.entry(denyOnly.request.responseID))
        try await assertEntryUnchanged()
    }

    func testOnlyTheFirstVerifiedDecisionConsumesTheEntry() async throws {
        try await assertEntryUnchanged()
        let deny = try await fixture.phone.messenger.sealer.sealApprovalDecision(.deny, answering: try fixture.phoneRequest(),
                                                                                approvalReason: "Deny")
        XCTAssertEqual(deny.messageID, request.request.responseID)
        fixture.harness.transport.insert(deny.envelope, intoInboxOf: fixture.mac.id)
        await XCTAssertEqualAsync(try await fixture.mac.poll().refusals, [.replayed], "it shares the response ID")
        // A messenger without the processed IDs passes it to the handler, whose entry is consumed.
        fixture.mac.restart()
        try await assertRefused(deny.envelope, at: fixture.mac, .bindingMismatch, reachesHandler: true)
        XCTAssertEqual(fixture.outstanding.applied.count, 1)
    }

    // MARK: The other kinds' bindings

    func testRequestClosedReceiptAndConfirmationWithAnotherPairingIDAreRefused() async throws {
        let other = PairingID(rawValue: RandomBytes.make(16))!
        let digest = request.requestDigest
        var requestFields = ApprovalRequest.Fields(decoding: request.request)
        requestFields.pairingID = other
        try await assertRefused(try ApprovalFixture.seal(.approvalRequest, requestFields.encoded, from: fixture.mac,
                                                         to: fixture.phone, sentAt: now, lifetime: 420),
                                at: fixture.phone, .bindingMismatch)
        try await assertRefused(try ApprovalFixture.seal(.approvalClosed, ApprovalClosed.encode(
            pairingID: other, requestDigest: digest, outcome: .expired, appliedCode: nil, appliedDuration: 0),
                                                         from: fixture.mac, to: fixture.phone, sentAt: now),
                                at: fixture.phone, .bindingMismatch)
        try await assertRefused(try ApprovalFixture.seal(.approvalReceipt, ApprovalReceipt.encode(pairingID: other,
                                                                                                  requestDigest: digest),
                                                         from: fixture.phone, to: fixture.mac,
                                                         messageID: ApprovalReceipt.receiptID(for: request.request.responseID),
                                                         sentAt: now),
                                at: fixture.mac, .bindingMismatch)
        let proof = Data(repeating: 1, count: 32)
        let statement = ApproverConfirmation.statement(phone: fixture.phone.id, mac: fixture.mac.id, pairingID: other,
                                                       codeProof: proof)
        let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
        try await assertRefused(try ApprovalFixture.seal(.approverConfirmation, ApproverConfirmation.encode(
            pairingID: other, codeProof: proof, signature: signature), from: fixture.phone, to: fixture.mac, sentAt: now),
                                at: fixture.mac, .bindingMismatch)
    }

    func testConfirmationNotSignedByTheApprovalKeyOverItsStatementIsRefused() async throws {
        let pairingID = try await fixture.phoneEntryForMac().pairingID
        let proof = ApproverCode.random().proof(mac: fixture.mac.id, phone: fixture.phone.id, pairingID: pairingID)
        let statement = ApproverConfirmation.statement(phone: fixture.phone.id, mac: fixture.mac.id, pairingID: pairingID,
                                                       codeProof: proof)
        let otherMac = ApproverConfirmation.statement(phone: fixture.phone.id, mac: SoftwareDeviceIdentity().deviceID,
                                                      pairingID: pairingID, codeProof: proof)
        let signatures = [try fixture.phone.identity.signWithMessageKey(statement),
                          try await fixture.phone.identity.signWithApprovalKey(otherMac, reason: "test"),
                          try P256.Signing.PrivateKey().signature(for: statement).rawRepresentation]
        for signature in signatures {
            let payload = ApproverConfirmation.encode(pairingID: pairingID, codeProof: proof, signature: signature)
            try await assertRefused(try ApprovalFixture.seal(.approverConfirmation, payload, from: fixture.phone,
                                                             to: fixture.mac, sentAt: now),
                                    at: fixture.mac, .badSignature)
        }
    }

    func testRequestTimesAreCheckedAgainstItsInnerMessage() async throws {
        var fields = ApprovalRequest.Fields(decoding: request.request)
        fields.deadline = now + 60
        try await assertRefused(try ApprovalFixture.seal(.approvalRequest, fields.encoded, from: fixture.mac, to: fixture.phone,
                                                         sentAt: now, lifetime: 361),
                                at: fixture.phone, .lifetimeTooLong)
        fields.deadline = now
        try await assertRefused(try ApprovalFixture.seal(.approvalRequest, fields.encoded, from: fixture.mac, to: fixture.phone,
                                                         sentAt: now, lifetime: 300),
                                at: fixture.phone, .malformed)
        fields.deadline = now + 301
        try await assertRefused(try ApprovalFixture.seal(.approvalRequest, fields.encoded, from: fixture.mac, to: fixture.phone,
                                                         sentAt: now, lifetime: 600),
                                at: fixture.phone, .malformed)
    }
}

extension ApprovalRequest.Fields {
    /// The fields of a decoded request, to change one and encode again.
    init(decoding request: ApprovalRequest) {
        self.init(pairingID: request.pairingID, responseID: request.responseID, bindingDigest: request.bindingDigest,
                  deadline: request.deadlineSeconds, launchTime: UnixTime.seconds(request.launchTime),
                  offers: request.offers.rawValue, timedDuration: request.timedDuration,
                  displayFlags: request.deliveryMetadataUnavailable ? 1 : 0, shortenedFlags: request.shortened.rawValue,
                  texts: [request.requesterName, request.purpose, request.credentialName, request.commandLine,
                          request.workingDirectory, request.executableName],
                  rows: request.deliveryRows)
    }
}
