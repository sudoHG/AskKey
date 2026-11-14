import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Turning a paired iPhone's approval on with system authentication and the
/// six-digit approver code (ADR 0014 → Approvers).
@MainActor
final class ApproverConfirmationTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
        try await harness.pairPhone()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    private var coordinator: DeviceCoordinator { harness.coordinator }

    private func row() throws -> PairedDeviceRow {
        try XCTUnwrap(coordinator.devices.first { $0.id == harness.phone.deviceID })
    }

    private func start() async throws -> ApproverCode {
        await coordinator.startApproverConfirmation(for: harness.phone.deviceID)
        return try XCTUnwrap(coordinator.approverCode)
    }

    private func wrongCode(_ code: ApproverCode) -> String {
        String(format: "%06d", ((Int(code.digits) ?? 0) + 1) % 1_000_000)
    }

    private func confirm(_ phone: SimulatedPairingPhone, typing code: String) async throws {
        try await phone.confirmApprover(typing: code, for: XCTUnwrap(harness.macDeviceID))
        await coordinator.refresh()
    }

    func testMatchingCodeFromTheSelectedIPhoneTurnsApprovalOn() async throws {
        XCTAssertFalse(try row().isApprover)
        let code = try await start()
        XCTAssertEqual(harness.script.authenticationReasons.last, ManagementAuthenticationAction.approveDevice.reasonKey)
        guard case .waitingForIPhone(_, let expiresAt, let remaining) = coordinator.approverConfirmation else {
            return XCTFail("the sheet waits for the iPhone")
        }
        XCTAssertEqual(expiresAt, harness.clock.now().addingTimeInterval(300))
        XCTAssertEqual(remaining, 3)
        XCTAssertEqual(code.formatted.count, 7)
        XCTAssertFalse(String(reflecting: coordinator.approverConfirmation).contains(code.digits))
        XCTAssertFalse(String(reflecting: code).contains(code.digits), "the code's description is redacted")
        try await confirm(harness.phone, typing: code.formatted)
        guard case .enabled(let device) = coordinator.approverConfirmation else {
            return XCTFail("approval is on, not \(String(describing: coordinator.approverConfirmation))")
        }
        XCTAssertTrue(device.isApprover)
        XCTAssertTrue(try row().isApprover, "the flag was written through the Vault")
        XCTAssertNotNil(try harness.generation(of: harness.phone), "the device is in the active-approver set")
        XCTAssertNil(coordinator.approverCode)
        XCTAssertTrue(harness.script.loggedEvents.contains(.approverEnabled))
        XCTAssertFalse(harness.script.loggedEvents.map { String(describing: $0) }.joined().contains(code.digits))
    }

    func testWrongCodesCountAndTheThirdEndsTheAttempt() async throws {
        let code = try await start()
        try await confirm(harness.phone, typing: wrongCode(code))
        guard case .waitingForIPhone(_, _, 2) = coordinator.approverConfirmation else {
            return XCTFail("one wrong code counts")
        }
        try await confirm(harness.phone, typing: wrongCode(code))
        try await confirm(harness.phone, typing: wrongCode(code))
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.tooManyWrongCodes))
        XCTAssertNil(coordinator.approverCode)
        XCTAssertFalse(try row().isApprover)
        // The Vault's approver authorization ended with the attempt.
        let registry = try harness.vault.pairedDeviceRegistry()
        let current = try row()
        do {
            _ = try await registry.apply(.setApprover(current.id, pairingID: current.pairingID, enabled: true))
            XCTFail("the flag needs a new authorization")
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, .approverNotAuthorized)
        }
    }

    func testFiveMinutesEndTheAttempt() async throws {
        let code = try await start()
        harness.clock.advance(by: 299)
        let goesOn = await coordinator.approverLoopStep()
        XCTAssertTrue(goesOn)
        harness.clock.advance(by: 1)
        let stopped = await coordinator.approverLoopStep()
        XCTAssertFalse(stopped)
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.expired))
        try await confirm(harness.phone, typing: code.formatted)
        XCTAssertFalse(try row().isApprover, "a confirmation after the expiry does nothing")
        XCTAssertTrue(harness.refusals.contains(.noSession))
    }

    func testMatchingCodeFromAnotherDeviceEndsTheAttemptAndIsReported() async throws {
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        let code = try await start()
        try await confirm(second, typing: code.formatted)
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.enteredOnOtherDevice(name: "Synthetic Phone Two")))
        XCTAssertTrue(harness.script.loggedEvents.contains(.approverCodeEnteredElsewhere))
        XCTAssertTrue(coordinator.devices.allSatisfy { !$0.isApprover })
        XCTAssertNil(try harness.generation(of: second))
    }

    func testNonMatchingCodeFromAnotherDeviceIsRefusedWithoutCounting() async throws {
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        let code = try await start()
        try await confirm(second, typing: wrongCode(code))
        guard case .waitingForIPhone(_, _, 3) = coordinator.approverConfirmation else {
            return XCTFail("not counted")
        }
        XCTAssertTrue(harness.refusals.contains(.bindingMismatch))
        try await confirm(harness.phone, typing: code.formatted)
        XCTAssertTrue(try row().isApprover)
    }

    func testCancelledOrFailedAuthenticationShowsNoCode() async throws {
        harness.script.authenticationResults = [.cancelled, .failed]
        await coordinator.startApproverConfirmation(for: harness.phone.deviceID)
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.authenticationCancelled))
        await coordinator.startApproverConfirmation(for: harness.phone.deviceID)
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.authenticationFailed))
        XCTAssertNil(coordinator.approverCode)
    }

    func testClosingTheSheetDuringAuthenticationShowsNoCode() async throws {
        harness.script.duringAuthentication = { [weak self] in self?.coordinator.cancelApproverConfirmation() }
        await coordinator.startApproverConfirmation(for: harness.phone.deviceID)
        XCTAssertNil(coordinator.approverConfirmation)
        XCTAssertNil(coordinator.approverCode)
    }

    func testTurningApprovalOnNeedsTheManagementSession() async throws {
        let prompts = harness.script.authenticationReasons.count
        harness.script.managementActive = false
        await coordinator.startApproverConfirmation(for: harness.phone.deviceID)
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.managementRequired))
        XCTAssertEqual(harness.script.authenticationReasons.count, prompts, "no prompt opened")
    }

    func testAnUnusableIdentityEndsTheAttempt() async throws {
        _ = try await start()
        coordinator.identityBecameUnusable()
        XCTAssertEqual(coordinator.approverConfirmation, .ended(.unavailable))
        XCTAssertNil(coordinator.approverCode)
    }

    func testClosingTheSheetOrLockingManagementDiscardsTheCode() async throws {
        let first = try await start()
        coordinator.cancelApproverConfirmation()
        XCTAssertNil(coordinator.approverConfirmation)
        XCTAssertNil(coordinator.approverCode)
        try await confirm(harness.phone, typing: first.formatted)
        XCTAssertFalse(try row().isApprover)

        let second = try await start()
        harness.script.managementActive = false
        await coordinator.managementSessionEnded()
        XCTAssertNil(coordinator.approverConfirmation)
        try await confirm(harness.phone, typing: second.formatted)
        XCTAssertFalse(try row().isApprover)
    }
}
