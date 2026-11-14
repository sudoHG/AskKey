@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Two simulated devices with software keys over the in-memory transport:
/// each kind 10–14 message round-trips (ADR 0014; #310 acceptance 2).
final class ApprovalFlowTests: XCTestCase {
    func testKindsUseTheirRecordTypesLifetimesAndBaseMode() {
        let approval: [MessageKind] = [.approvalRequest, .approvalDecision, .approvalClosed, .approvalReceipt,
                                       .approverConfirmation]
        XCTAssertEqual(approval.map(\.rawValue), [10, 11, 12, 13, 14])
        for kind in approval {
            XCTAssertEqual(kind.recordType, kind == .approvalRequest ? .alert : .quiet)
            XCTAssertEqual(kind.maximumLifetime, 600)
            XCTAssertFalse(kind.usesPreSharedKey)
            XCTAssertFalse(kind.isPairing)
            XCTAssertTrue(kind.isApproval)
        }
        XCTAssertTrue(MessageKind.allCases.filter { !approval.contains($0) }.allSatisfy { !$0.isApproval })
    }

    func testRequestReachesThePhoneWithEveryField() async throws {
        let fixture = try await ApprovalFixture.make()
        let sealed = try await fixture.sendRequest(deadlineIn: 120)
        let envelope = sealed.sealed.envelope
        XCTAssertEqual(envelope.recordType, .alert)
        XCTAssertEqual(envelope.kind, 10)
        XCTAssertEqual(envelope.expiresAt.timeIntervalSince(envelope.sentAt), 420, "the deadline plus 5 minutes")
        let report = try await fixture.phone.poll()
        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(fixture.harness.transport.records(in: fixture.phone.id), [], "processed and deleted")

        let request = try fixture.phoneRequest()
        XCTAssertEqual(request.senderID, fixture.mac.id)
        let phoneEntry = try await fixture.phoneEntryForMac()
        XCTAssertEqual(request.pairingID, phoneEntry.pairingID)
        XCTAssertEqual(request.digest, sealed.requestDigest)
        XCTAssertEqual(request.requestDigest, sealed.requestDigest)
        XCTAssertEqual(request.envelope, envelope)
        XCTAssertEqual(request.messageID, sealed.sealed.messageID)
        guard case .request(let content) = request.message else { return XCTFail("a request") }
        XCTAssertEqual(content, sealed.request)
        XCTAssertNotEqual(content.responseID, sealed.sealed.messageID, "the response ID is its own random value")
        XCTAssertEqual(content.bindingDigest, ApprovalFixture.binding)
        XCTAssertEqual(content.offers, .all)
        XCTAssertEqual(content.timedDuration, 1_800)
        XCTAssertEqual(content.deadline, envelope.sentAt.addingTimeInterval(120))
        XCTAssertEqual(content.credentialName, "GitHub Token")
    }

    func testEverySealingGetsItsOwnResponseIDAndDigest() async throws {
        let fixture = try await ApprovalFixture.make()
        let first = try await fixture.sendRequest()
        let second = try await fixture.sendRequest()
        XCTAssertNotEqual(first.request.responseID, second.request.responseID)
        XCTAssertNotEqual(first.requestDigest, second.requestDigest)
    }

    private func decide(_ code: ApprovalDecisionCode, offers: ApprovalOffers = .all,
                        fixture: ApprovalFixture) async throws -> (SealedApprovalRequest, SealedDeviceMessage) {
        let sealed = try await fixture.sendRequest(offers: offers)
        try await fixture.phone.poll()
        let decision = try await fixture.phone.messenger.sealer.sealApprovalDecision(code, answering: try fixture.phoneRequest(),
                                                                                    approvalReason: "Allow the request")
        try await fixture.harness.transport.send(decision.envelope)
        return (sealed, decision)
    }

    func testAllowOnceTimedAndDenyRoundTripToTheMacHandler() async throws {
        var bodySizes: [ApprovalDecisionCode: Int] = [:]
        for code in ApprovalDecisionCode.allCases {
            let fixture = try await ApprovalFixture.make()
            let promptsBefore = fixture.phone.identity.approvalReasons.count
            let (request, decision) = try await decide(code, fixture: fixture)
            XCTAssertEqual(fixture.phone.identity.approvalReasons.count, promptsBefore + (code == .deny ? 0 : 1),
                           "only Allow asks for Face ID")
            XCTAssertEqual(decision.envelope.recordType, .quiet)
            XCTAssertEqual(decision.envelope.recordName, request.request.responseID.text, "the message ID is the response ID")
            XCTAssertEqual(decision.envelope.expiresAt.timeIntervalSince(decision.envelope.sentAt), 600)
            bodySizes[code] = decision.envelope.body.count

            let inner = try PairingRuleTests.open(decision.envelope, with: fixture.mac)
            XCTAssertEqual(inner.payload.count, ApprovalDecision.byteCount)
            let slot = inner.payload.suffix(64)
            let ceiling: UInt64 = code == .timedAllowance ? 1_800 : 0
            if code == .deny {
                XCTAssertEqual(slot, Data(count: 64), "Deny carries a zero slot")
            } else {
                let statement = ApprovalDecision.statement(approver: fixture.phone.id, requester: fixture.mac.id,
                                                           pairingID: try await fixture.macEntryForPhone().pairingID,
                                                           requestDigest: request.requestDigest, code: code,
                                                           durationCeiling: ceiling)
                let signature = try P256.Signing.ECDSASignature(rawRepresentation: slot)
                XCTAssertTrue(fixture.phone.identity.approvalPublicKey.isValidSignature(signature, for: statement))
                XCTAssertFalse(fixture.phone.identity.messagePublicKey.isValidSignature(signature, for: statement))
            }

            let report = try await fixture.mac.poll()
            XCTAssertEqual(report.processed, 1, "\(code)")
            XCTAssertEqual(fixture.harness.transport.records(in: fixture.mac.id), [])
            let applied = try XCTUnwrap(fixture.outstanding.applied.first)
            XCTAssertEqual(applied.senderID, fixture.phone.id)
            let macEntry = try await fixture.macEntryForPhone()
            XCTAssertEqual(applied.pairingID, macEntry.pairingID)
            XCTAssertEqual(applied.messageID, request.request.responseID)
            guard case .decision(let content) = applied.message else { return XCTFail("a decision") }
            XCTAssertEqual(content.requestDigest, request.requestDigest)
            XCTAssertEqual(applied.requestDigest, request.requestDigest, "not the decision's own digest")
            XCTAssertNotEqual(applied.digest, request.requestDigest)
            XCTAssertEqual(content.code, code)
            XCTAssertEqual(content.durationCeiling, ceiling)
            XCTAssertEqual(content.approvalSignature == nil, code == .deny)
            XCTAssertNil(fixture.outstanding.entry(request.request.responseID), "the decision consumed the entry")
        }
        XCTAssertEqual(Set(bodySizes.values).count, 1, "Allow and Deny have the same length")
    }

    func testTheApproverCannotSignACodeTheRequestDidNotOffer() async throws {
        let fixture = try await ApprovalFixture.make()
        try await fixture.sendRequest(offers: .denyOrAllowOnce)
        try await fixture.phone.poll()
        let request = try fixture.phoneRequest()
        do {
            _ = try await fixture.phone.messenger.sealer.sealApprovalDecision(.timedAllowance, answering: request,
                                                                             approvalReason: "Allow")
            XCTFail("not offered")
        } catch {
            XCTAssertEqual(error as? ApprovalMessageError, .notOffered)
        }
        XCTAssertTrue(fixture.phone.identity.approvalReasons.allSatisfy { !$0.contains("Allow") }, "no prompt")
        fixture.phone.identity.approvalBehavior = .cancel
        do {
            _ = try await fixture.phone.messenger.sealer.sealApprovalDecision(.allowOnce, answering: request,
                                                                             approvalReason: "Allow")
            XCTFail("a cancelled prompt seals nothing")
        } catch {
            XCTAssertEqual(error as? DeviceIdentityError, .authenticationCancelled)
        }
    }

    func testClosedReceiptAndConfirmationRoundTrip() async throws {
        let fixture = try await ApprovalFixture.make()
        let sealed = try await fixture.sendRequest()
        try await fixture.phone.poll()
        let request = try fixture.phoneRequest()

        // Receipt: the phone sends it under the receipt ID; the Mac marks the request delivered.
        let receipt = try fixture.phone.messenger.sealer.sealApprovalReceipt(answering: request)
        XCTAssertEqual(receipt.messageID, ApprovalReceipt.receiptID(for: sealed.request.responseID))
        XCTAssertEqual(receipt.envelope.recordType, .quiet)
        try await fixture.harness.transport.send(receipt.envelope)
        await XCTAssertEqualAsync(try await fixture.mac.poll().processed, 1)
        XCTAssertEqual(fixture.outstanding.entry(sealed.request.responseID)?.delivered, true)
        guard case .receipt(let receiptContent)? = fixture.outstanding.messages.last?.message else { return XCTFail("receipt") }
        XCTAssertEqual(receiptContent.requestDigest, sealed.requestDigest)

        // Closed: the Mac tells the phone the request was applied with a timed allowance.
        let closed = try fixture.mac.messenger.sealer.sealApprovalClosed(.applied, appliedCode: .timedAllowance,
                                                                         appliedDuration: 1_500,
                                                                         requestDigest: sealed.requestDigest,
                                                                         to: try await fixture.macEntryForPhone())
        XCTAssertEqual(closed.envelope.recordType, .quiet)
        try await fixture.harness.transport.send(closed.envelope)
        await XCTAssertEqualAsync(try await fixture.phone.poll().processed, 1)
        let closedMessage = try XCTUnwrap(fixture.phoneInbox.messages.last)
        XCTAssertEqual(closedMessage.senderID, fixture.mac.id)
        guard case .closed(let closedContent) = closedMessage.message else { return XCTFail("closed") }
        XCTAssertEqual(closedContent.outcome, .applied)
        XCTAssertEqual(closedContent.appliedCode, .timedAllowance)
        XCTAssertEqual(closedContent.appliedDuration, 1_500)
        XCTAssertEqual(closedContent.requestDigest, sealed.requestDigest)
        let macEntry = try await fixture.macEntryForPhone()
        XCTAssertThrowsError(try fixture.mac.messenger.sealer.sealApprovalClosed(.expired, appliedCode: .deny,
                                                                                 requestDigest: sealed.requestDigest,
                                                                                 to: macEntry))
        XCTAssertThrowsError(try fixture.mac.messenger.sealer.sealApprovalClosed(.applied, appliedCode: .timedAllowance,
                                                                                 appliedDuration: 7_201,
                                                                                 requestDigest: sealed.requestDigest,
                                                                                 to: macEntry)) {
            XCTAssertEqual($0 as? ApprovalMessageError, .invalidClosedOutcome)
        }

        // Confirmation: the phone sends the proof of the typed code; the Mac's handler compares it.
        let code = ApproverCode.random()
        let typed = try XCTUnwrap(ApproverCode(typed: code.formatted))
        let confirmation = try await fixture.phone.messenger.sealer.sealApproverConfirmation(
            typed, to: try await fixture.phoneEntryForMac(), approvalReason: "Approve requests")
        XCTAssertEqual(fixture.phone.identity.approvalReasons.last, "Approve requests")
        try await fixture.harness.transport.send(confirmation.envelope)
        await XCTAssertEqualAsync(try await fixture.mac.poll().processed, 1)
        let confirmed = try XCTUnwrap(fixture.outstanding.messages.last)
        guard case .confirmation(let content) = confirmed.message else { return XCTFail("confirmation") }
        XCTAssertNil(confirmed.requestDigest)
        XCTAssertEqual(confirmed.senderID, fixture.phone.id)
        XCTAssertTrue(code.matches(proof: content.codeProof, mac: fixture.mac.id, phone: fixture.phone.id,
                                   pairingID: confirmed.pairingID))
        XCTAssertFalse(ApproverCode(typed: code.digits == "000000" ? "000001" : "000000")!
            .matches(proof: content.codeProof, mac: fixture.mac.id, phone: fixture.phone.id, pairingID: confirmed.pairingID))
    }

    func testAClosedMessageIsHandledBeforeTheRequestItEnds() async throws {
        let fixture = try await ApprovalFixture.make()
        let sealed = try await fixture.sendRequest()
        let closed = try fixture.mac.messenger.sealer.sealApprovalClosed(.decidedOnMac, requestDigest: sealed.requestDigest,
                                                                         to: try await fixture.macEntryForPhone())
        try await fixture.harness.transport.send(closed.envelope)
        XCTAssertEqual(fixture.harness.transport.records(in: fixture.phone.id).map(\.kind), [10, 12])
        try await fixture.phone.poll()
        let kinds = fixture.phoneInbox.messages.map { message -> String in
            if case .closed = message.message { return "closed" }
            return "request"
        }
        XCTAssertEqual(kinds, ["closed", "request"], "kind 12 ranks before kind 10 within one fetch")
    }

    func testAMessageUnderTheNewPairingFromTheSessionPeerIsHeldUntilThePeerIsAdded() async throws {
        let fixture = try await ApprovalFixture.make()
        let (mac, phone, harness) = (fixture.mac!, fixture.phone!, fixture.harness)
        let old = try await fixture.macEntryForPhone()
        // Pairing again: the phone adds the Mac under the new pairing before the Mac adds the phone.
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.delaying(.pairingConfirmation, from: phone.id)
        try await mac.confirm()
        try await phone.confirm()
        try await phone.poll()
        let new = try await fixture.phoneEntryForMac()
        XCTAssertNotEqual(new.pairingID, old.pairingID, "the phone holds the new pairing")
        await XCTAssertEqualAsync(try await fixture.macEntryForPhone().pairingID, old.pairingID)

        let confirmation = try await phone.messenger.sealer.sealApproverConfirmation(ApproverCode.random(), to: new,
                                                                                    approvalReason: "Approve")
        try await harness.transport.send(confirmation.envelope)
        let early = try await mac.poll()
        XCTAssertEqual(early.outcomes[confirmation.envelope.recordName], .keptForSession)
        XCTAssertTrue(fixture.outstanding.messages.isEmpty, "the handler has not seen it")
        XCTAssertEqual(harness.transport.records(in: mac.id).map(\.recordName), [confirmation.envelope.recordName])

        harness.transport.releaseDelayed()
        let later = try await mac.poll()
        XCTAssertEqual(later.outcomes[confirmation.envelope.recordName], .processed)
        XCTAssertEqual(fixture.outstanding.messages.map(\.pairingID), [new.pairingID])
        XCTAssertEqual(fixture.removals.entries.map(\.pairingID), [old.pairingID], "the old entry was announced first")
    }

    func testWithoutAHandlerApprovalMessagesAreRefused() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        let entry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        let sealed = try mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding,
            deadline: harness.clock.now().addingTimeInterval(60), launchTime: harness.clock.now(), offers: .denyOnly,
            timedDuration: 0, to: entry)
        try await harness.transport.send(sealed.sealed.envelope)
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.unexpectedKind])
        XCTAssertEqual(harness.transport.records(in: phone.id), [])
    }

    func testSealingRefusesADeadlineThatPassedOrIsTooFarAway() async throws {
        let fixture = try await ApprovalFixture.make()
        let entry = try await fixture.macEntryForPhone()
        let now = fixture.harness.clock.now()
        for deadline in [now, now.addingTimeInterval(-1), now.addingTimeInterval(301)] {
            XCTAssertThrowsError(try fixture.mac.messenger.sealer.sealApprovalRequest(
                ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding, deadline: deadline,
                launchTime: now, offers: .denyOnly, timedDuration: 0, to: entry)) {
                XCTAssertEqual($0 as? ApprovalMessageError, .deadlineOutOfRange)
            }
        }
        let sealed = try fixture.mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding, deadline: now.addingTimeInterval(300.9),
            launchTime: now, offers: .denyOnly, timedDuration: 0, to: entry)
        XCTAssertEqual(sealed.request.deadline, now.addingTimeInterval(300), "rounded down to the second")
        XCTAssertEqual(sealed.sealed.envelope.expiresAt.timeIntervalSince(sealed.sealed.envelope.sentAt), 600,
                       "at most 10 minutes")
    }
}
