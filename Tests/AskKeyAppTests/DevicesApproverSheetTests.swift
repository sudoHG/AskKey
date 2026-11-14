import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices

/// Settings → Devices → **Approve agent requests** and its sheet (ADR 0014
/// → Approvers): off by default, what leaves the Mac before system
/// authentication, then the code, every way an attempt ends, and turning it
/// off without authentication. Nothing the sheet's text or the model
/// publishes carries the code.
@MainActor
final class DevicesApproverSheetTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!
    private var model: DevicesSettingsModel!
    private var previousLanguage = AppLanguage.current

    override func setUp() async throws {
        previousLanguage = AppLanguage.current
        AppLanguage.current = "en"
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
        try await harness.pairPhone()
        model = DevicesSettingsModel(coordinator: harness.coordinator)
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
        model = nil
        AppLanguage.current = previousLanguage
    }

    private var coordinator: DeviceCoordinator { harness.coordinator }

    private func row() throws -> PairedDeviceRow {
        try XCTUnwrap(coordinator.devices.first { $0.id == harness.phone.deviceID })
    }

    private func sheet() throws -> ApproverSheetPresentation {
        try XCTUnwrap(model.approverSheet)
    }

    private func typeOnPhone(_ code: String, phone: SimulatedPairingPhone? = nil) async throws {
        try await (phone ?? harness.phone).confirmApprover(typing: code, for: XCTUnwrap(harness.macDeviceID))
        await coordinator.refresh()
    }

    /// The system authentication prompts for turning approval on.
    private var approverPrompts: Int {
        harness.script.authenticationReasons.filter { $0 == ManagementAuthenticationAction.approveDevice.reasonKey }.count
    }

    private func wrong(_ code: ApproverCode) -> String {
        String(format: "%06d", ((Int(code.digits) ?? 0) + 1) % 1_000_000)
    }

    /// Everything the sheet says, for checks that nothing names the code.
    private func sheetText(_ sheet: ApproverSheetPresentation) -> String {
        [sheet.title, sheet.message ?? "", sheet.feedback ?? "", String(reflecting: sheet.stage),
         String(reflecting: coordinator.approverConfirmation)].joined(separator: "\n")
    }

    func testApprovalIsOffAndTurningItOnFirstSaysWhatLeavesTheMac() async throws {
        XCTAssertFalse(try row().isApprover)
        XCTAssertEqual(DevicesPresentation.approverCaption(try row()), "Agent requests aren't sent to this iPhone.")
        await model.setApprover(try row(), enabled: true)
        let intro = try sheet()
        XCTAssertEqual(intro.stage, .intro)
        XCTAssertTrue(intro.showsWhatLeaves)
        XCTAssertEqual(intro.title, "Let “Synthetic Phone” Approve Agent Requests?")
        XCTAssertNil(coordinator.approverConfirmation)
        XCTAssertNil(coordinator.approverCode, "no code before system authentication")
        XCTAssertEqual(approverPrompts, 0, "the first step only explains")
    }

    func testContinueAuthenticatesThenShowsTheCodeUntilTheIPhoneConfirmsIt() async throws {
        await model.setApprover(try row(), enabled: true)
        await model.continueApprover()
        XCTAssertEqual(harness.script.authenticationReasons.last, ManagementAuthenticationAction.approveDevice.reasonKey)
        XCTAssertEqual(approverPrompts, 1)
        let code = try XCTUnwrap(coordinator.approverCode)
        guard case .code(let expiresAt) = try sheet().stage else { return XCTFail("the code step") }
        XCTAssertEqual(expiresAt, harness.clock.now().addingTimeInterval(300))
        XCTAssertEqual(try sheet().title, "Type This Code on “Synthetic Phone”")
        XCTAssertNil(try sheet().feedback)
        XCTAssertFalse(sheetText(try sheet()).contains(code.digits))
        XCTAssertFalse(sheetText(try sheet()).contains(code.formatted))

        try await typeOnPhone(wrong(code))
        XCTAssertEqual(try sheet().feedback, "The code typed on the iPhone doesn't match. 2 attempts left.")
        try await typeOnPhone(wrong(code))
        XCTAssertEqual(try sheet().feedback, "The code typed on the iPhone doesn't match. 1 attempt left.")
        XCTAssertFalse(sheetText(try sheet()).contains(code.digits))

        try await typeOnPhone(code.formatted)
        XCTAssertEqual(try sheet().stage, .enabled)
        XCTAssertEqual(try sheet().title, "Approval Is On")
        XCTAssertTrue(try row().isApprover)
        model.closeApproverSheet()
        XCTAssertFalse(model.isApproverSheetPresented)
        XCTAssertEqual(DevicesPresentation.approverCaption(try row()), "Agent requests can also be decided on this iPhone.")
    }

    func testTurningApprovalOffAsksForNoAuthentication() async throws {
        try await harness.enableApprover(harness.phone)
        let prompts = harness.script.authenticationReasons.count
        XCTAssertTrue(try row().isApprover)
        await model.setApprover(try row(), enabled: false)
        XCTAssertFalse(try row().isApprover)
        XCTAssertEqual(harness.script.authenticationReasons.count, prompts)
        XCTAssertFalse(model.isApproverSheetPresented)
        XCTAssertNil(try harness.generation(of: harness.phone), "the device left the active-approver set")
    }

    func testThreeWrongCodesExpiryAndStartingAgain() async throws {
        await model.setApprover(try row(), enabled: true)
        await model.continueApprover()
        let first = try XCTUnwrap(coordinator.approverCode)
        for _ in 0..<3 { try await typeOnPhone(wrong(first)) }
        XCTAssertEqual(try sheet().stage, .ended(canStartAgain: true))
        XCTAssertEqual(try sheet().title, "Approval Stays Off")
        XCTAssertEqual(try sheet().message, "The code typed on the iPhone didn't match three times, so this attempt ended. Start again to get a new code.")

        await model.startApproverAgain()
        XCTAssertEqual(approverPrompts, 2, "starting again repeats system authentication")
        guard case .code = try sheet().stage else { return XCTFail("a new code") }
        harness.clock.advance(by: 301)
        _ = await coordinator.approverLoopStep()
        XCTAssertEqual(try sheet().message, "The code expired before the iPhone confirmed it. Start again to get a new code.")
        XCTAssertNil(coordinator.approverCode)
        XCTAssertFalse(try row().isApprover)
    }

    func testACodeTypedOnAnotherIPhoneEndsTheAttemptAndNamesIt() async throws {
        let other = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(other, name: "Other Phone")
        await model.setApprover(try row(), enabled: true)
        await model.continueApprover()
        let code = try XCTUnwrap(coordinator.approverCode)
        try await typeOnPhone(code.formatted, phone: other)
        XCTAssertEqual(try sheet().stage, .ended(canStartAgain: true))
        XCTAssertEqual(try sheet().message, "The code was typed on “Other Phone”, not on the iPhone you chose, so this attempt ended. If you didn't type it there, remove that device. Otherwise start again and type the code on the iPhone you chose.")
        XCTAssertEqual(try sheet().device.id, harness.phone.deviceID, "the card still names the iPhone the person chose")
    }

    func testCancelledAuthenticationAndLockingManagementCloseNothingOpen() async throws {
        harness.script.authenticationResults = [.cancelled]
        await model.setApprover(try row(), enabled: true)
        await model.continueApprover()
        XCTAssertEqual(try sheet().message, "System authentication was cancelled. Nothing changed.")
        XCTAssertEqual(try sheet().stage, .ended(canStartAgain: true))
        await model.startApproverAgain()
        guard case .code = try sheet().stage else { return XCTFail("the code after authenticating again") }
        let open = coordinator.approverConfirmation
        await coordinator.managementSessionEnded()
        model.approverStateChanged(from: open, to: coordinator.approverConfirmation)
        XCTAssertFalse(model.isApproverSheetPresented, "the sheet closes with the attempt")
        XCTAssertNil(coordinator.approverCode)
    }

    func testMacRowsAndUnavailableServicesOfferNoApproval() async throws {
        let phone = try row()
        let mac = PairedDeviceRow(id: phone.id, pairingID: phone.pairingID, displayName: "Synthetic Mac", platform: .macOS,
                                  pairedAt: phone.pairedAt, lastDeliveryCheck: nil, reachability: .notReachedYet,
                                  isApprover: false)
        await model.setApprover(mac, enabled: true)
        XCTAssertFalse(model.isApproverSheetPresented)
        harness.backend.accountState = .noAccount
        await coordinator.devicesOpened()
        XCTAssertFalse(model.canChangeApprover(try row()))
        await model.setApprover(try row(), enabled: true)
        XCTAssertFalse(model.isApproverSheetPresented)
    }

    /// A lost iPhone's approval can be turned off while the Mac can't reach iCloud.
    func testApprovalTurnsOffWhileICloudIsUnavailable() async throws {
        try await harness.enableApprover(harness.phone)
        harness.backend.accountState = .temporarilyUnavailable
        await coordinator.devicesOpened()
        XCTAssertNotEqual(coordinator.account, .available)
        XCTAssertTrue(model.canChangeApprover(try row()))
        await model.setApprover(try row(), enabled: false)
        XCTAssertFalse(try row().isApprover)
        XCTAssertNil(try harness.generation(of: harness.phone))
    }

    func testLeavingTheSectionClosesTheSheetAndDiscardsTheCode() async throws {
        await model.setApprover(try row(), enabled: true)
        await model.continueApprover()
        XCTAssertNotNil(coordinator.approverCode)
        model.sectionClosed()
        XCTAssertFalse(model.isApproverSheetPresented, "the next visit opens no sheet")
        XCTAssertNil(coordinator.approverCode)
        XCTAssertNil(coordinator.approverConfirmation)
    }

    func testEveryEndReasonSaysWhetherStartingAgainHelps() {
        let restartable: [ApproverConfirmationEndReason] = [.authenticationCancelled, .authenticationFailed, .expired,
                                                           .tooManyWrongCodes, .enteredOnOtherDevice(name: "x"), .notSaved]
        let final: [ApproverConfirmationEndReason] = [.managementRequired, .unavailable, .deviceRemoved]
        XCTAssertTrue(restartable.allSatisfy(ApproverSheetPresentation.canStartAgain(after:)))
        XCTAssertFalse(final.contains(where: ApproverSheetPresentation.canStartAgain(after:)))
        for reason in restartable + final {
            XCTAssertFalse(ApproverSheetPresentation.endMessage(reason).isEmpty)
        }
    }
}
