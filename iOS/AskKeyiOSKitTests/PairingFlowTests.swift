import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

@MainActor
final class PairingFlowTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
    }

    override func tearDown() async throws {
        world = nil
    }

    // MARK: Scanner

    func testScannerRefusesInvalidForeignAndExpiredCodesWithTheirOwnMessages() async throws {
        world.model.startPairing()
        let flow = try XCTUnwrap(world.model.pairing)
        XCTAssertEqual(flow.camera, .unavailable)

        await flow.handleScanned("https://example.com/not-a-pairing-code")
        XCTAssertEqual(flow.scanProblem, .notAPairingCode)
        XCTAssertEqual(flow.stage, .scanning)

        await flow.handleScanned(PairingQRPayload.prefix + "damaged")
        XCTAssertEqual(flow.scanProblem, .invalid)

        let qr = try await world.mac.startPairing(displayName: TestWorld.macName)
        world.clock.advance(by: 5 * 60 + 1)
        await flow.handleScanned(qr.text)
        XCTAssertEqual(flow.scanProblem, .expired)
        XCTAssertEqual(flow.stage, .scanning)
        XCTAssertTrue(world.cloud.sent(.pairingRequest, from: try world.phone.deviceID).isEmpty)
    }

    func testARefusedCodeThatStaysInViewIsNotHandledAgainUntilDismissed() async throws {
        world.model.startPairing()
        let flow = try XCTUnwrap(world.model.pairing)
        await flow.handleScanned("not a pairing code")
        flow.scanProblem = nil
        await flow.handleScanned("not a pairing code")
        XCTAssertNil(flow.scanProblem)
        flow.dismissScanProblem()
        await flow.handleScanned("not a pairing code")
        XCTAssertEqual(flow.scanProblem, .notAPairingCode)
    }

    func testCameraIsRequestedOnceWhenNotDetermined() async throws {
        world.camera.current = .notDetermined
        world.model.startPairing()
        let flow = try XCTUnwrap(world.model.pairing)
        await flow.prepareCamera()
        XCTAssertEqual(flow.camera, .authorized)
    }

    // MARK: Code

    func testNoCodeBeforeTheChallenge() async throws {
        let flow = try await world.scanMacCode()
        XCTAssertEqual(flow.stage, .waitingForCode)
        XCTAssertEqual(world.cloud.sent(.pairingRequest, from: try world.phone.deviceID).count, 1)
        await flow.refresh()
        XCTAssertEqual(flow.stage, .waitingForCode, "the Mac has not answered")
    }

    func testNoCodeUntilTheRevealIsSavedAndTheRetryKeepsItsMessageID() async throws {
        let phoneID = try world.phone.deviceID
        world.cloud.failSends { $0.kind == Int64(MessageKind.pairingReveal.rawValue) }
        let flow = try await world.scanMacCode()
        _ = try await world.mac.poll()
        await flow.refresh()
        XCTAssertEqual(flow.stage, .waitingForCode, "a verified challenge alone shows no code")
        world.cloud.failSends(where: nil)
        await flow.refresh()
        guard case .code(let display) = flow.stage else { return XCTFail("expected the code, got \(flow.stage)") }
        XCTAssertEqual(display.macName, TestWorld.macName)
        XCTAssertFalse(display.confirmed)
        XCTAssertEqual(display.digits.count, 7)
        let reveals = world.cloud.sent(.pairingReveal, from: phoneID)
        XCTAssertGreaterThanOrEqual(reveals.count, 2)
        XCTAssertEqual(Set(reveals.map(\.recordName)).count, 1, "a failed save is retried with the same message ID")
    }

    func testTheCodeMatchesWhatTheMacExpects() async throws {
        let (_, display) = try await world.reachCode()
        _ = try await world.mac.poll()
        try await world.mac.enterPairingCode(display.digits)
        guard case .codeAccepted? = await world.mac.pairingPhase else { return XCTFail("the Mac refused the code") }
    }

    func testConfirmSignsWithTheApprovalKeyAndSuccessWaitsForTheMac() async throws {
        let phone = try world.phone
        let (flow, display) = try await world.reachCode()
        await flow.confirm()
        XCTAssertEqual(phone.approvalReasons.count, 1)
        XCTAssertTrue(phone.approvalReasons[0].contains(TestWorld.macName))
        XCTAssertEqual(world.cloud.sent(.pairingConfirmation, from: phone.deviceID).count, 1)
        XCTAssertEqual(flow.stage, .code(PairingCodeDisplay(digits: display.digits, macName: TestWorld.macName,
                                                            confirmed: true)))
        XCTAssertTrue(world.model.pairedMacs.isEmpty, "nothing is stored before the Mac's confirmation")

        _ = try await world.mac.poll()
        try await world.mac.enterPairingCode(display.digits)
        try await world.mac.confirmPairing(approvalReason: "Pair")
        await flow.refresh()
        XCTAssertEqual(flow.stage, .paired(macName: TestWorld.macName))
        XCTAssertEqual(world.model.pairedMacs.map(\.name), [TestWorld.macName])
        XCTAssertNil(world.model.pairedMacs.first?.lastReachedAt, "not reached yet until a delivery check")
        _ = try await world.mac.poll()
        let macList = try await world.mac.pairedDevices()
        XCTAssertEqual(macList.map(\.deviceID), [phone.deviceID])
    }

    func testCancelledFaceIDSendsNothingAndCanBeRetried() async throws {
        let phone = try world.phone
        let (flow, _) = try await world.reachCode()
        phone.approvalBehavior = .cancel
        await flow.confirm()
        XCTAssertEqual(flow.confirmProblem, .cancelled)
        XCTAssertTrue(world.cloud.sent(.pairingConfirmation, from: phone.deviceID).isEmpty)
        guard case .code(let display) = flow.stage else { return XCTFail("the code must stay") }
        XCTAssertFalse(display.confirmed)

        phone.approvalBehavior = .fail
        await flow.confirm()
        XCTAssertEqual(flow.confirmProblem, .failed)
        XCTAssertTrue(world.cloud.sent(.pairingConfirmation, from: phone.deviceID).isEmpty)

        phone.approvalBehavior = .sign
        await flow.confirm()
        XCTAssertNil(flow.confirmProblem)
        XCTAssertEqual(phone.approvalReasons.count, 3, "every confirmation asks again")
        XCTAssertEqual(world.cloud.sent(.pairingConfirmation, from: phone.deviceID).count, 1)
    }

    func testCancelWithoutAChallengeSendsAWithdrawalAndStoresNothing() async throws {
        let phoneID = try world.phone.deviceID
        _ = try await world.scanMacCode()
        await world.model.closePairingAndWait()
        XCTAssertNil(world.model.pairing)
        XCTAssertEqual(world.cloud.sent(.pairingWithdrawal, from: phoneID).count, 1)
        XCTAssertTrue(world.cloud.sent(.pairingCancellation, from: phoneID).isEmpty)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
    }

    func testCancelAfterTheCodeSendsACancellationAndTheMacEndsToo() async throws {
        let phoneID = try world.phone.deviceID
        let (flow, _) = try await world.reachCode()
        await flow.confirm()
        await world.model.closePairingAndWait()
        XCTAssertEqual(world.cloud.sent(.pairingCancellation, from: phoneID).count, 1)
        _ = try await world.mac.poll()
        let macPhase = await world.mac.pairingPhase
        XCTAssertEqual(macPhase, .ended(.cancelledByPeer))
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        let macList = try await world.mac.pairedDevices()
        XCTAssertTrue(macList.isEmpty)
    }

    func testNoChallengeWithinSixtySecondsWithdrawsAndSaysNotToEnterACode() async throws {
        let phoneID = try world.phone.deviceID
        let flow = try await world.scanMacCode()
        world.clock.advance(by: 61)
        await flow.refresh()
        XCTAssertEqual(flow.stage, .failed(.noChallenge))
        XCTAssertFalse(flow.isSessionOpen)
        XCTAssertEqual(world.cloud.sent(.pairingWithdrawal, from: phoneID).count, 1)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
    }

    func testTheMacCancellingEndsThePairing() async throws {
        let (flow, _) = try await world.reachCode()
        await world.mac.cancelPairing()
        await flow.refresh()
        XCTAssertEqual(flow.stage, .failed(.cancelledByMac))
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
    }

    func testAnUnusableApprovalKeyLeadsToTheReset() async throws {
        let phone = try world.phone
        let (flow, _) = try await world.reachCode()
        phone.isUnusable = true
        await flow.confirm()
        XCTAssertEqual(world.model.stage, .unusableIdentity)
        XCTAssertNil(world.model.pairing)
    }

    func testSessionIsOpenOnlyBetweenTheScanAndTheOutcome() async throws {
        world.model.startPairing()
        let flow = try XCTUnwrap(world.model.pairing)
        XCTAssertFalse(flow.isSessionOpen)
        await world.model.closePairingAndWait()
        let (codeFlow, _) = try await world.reachCode()
        XCTAssertTrue(codeFlow.isSessionOpen)
    }
}

final class PairingCodeDisplayTests: XCTestCase {
    func testPrintingAStageNeverRevealsTheCode() {
        let stage = PairingFlowModel.Stage.code(PairingCodeDisplay(digits: "123 456", macName: "Mac", confirmed: false))
        for text in [String(describing: stage), String(reflecting: stage), "\(stage)"] {
            XCTAssertFalse(text.contains("123"), text)
            XCTAssertFalse(text.contains("456"), text)
        }
    }
}
