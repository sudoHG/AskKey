import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Settings → Devices as the person drives it (#288): the model over the
/// real coordinator, with software keys, the in-memory transport and a
/// simulated iPhone.
@MainActor
final class DevicesSettingsModelTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!
    private var model: DevicesSettingsModel!
    private let previousLanguage = AppLanguage.current

    override func setUp() async throws {
        AppLanguage.current = "en"
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
        model = DevicesSettingsModel(coordinator: harness.coordinator)
    }

    override func tearDown() async throws {
        model = nil
        try harness.close()
        harness = nil
        AppLanguage.current = previousLanguage
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld, "no test leaves idle expiry held")
    }

    func testTheSectionIsAbsentWithoutCloudKitAndWithoutDeviceServices() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let coordinator = DeviceCoordinator(environment: DeviceCoordinatorEnvironment(
            vault: library.vault, backend: nil, inboxState: VaultDeviceInboxStateStore(vault: library.vault),
            authenticate: { _ in .authenticated(.allow) }, isManagementSessionActive: { true },
            automaticPolling: false
        ))
        XCTAssertFalse(DevicesSettingsModel(coordinator: coordinator).isSectionVisible)
        // This process has no CloudKit entitlement, so whatever it installed is not configured.
        XCTAssertFalse(VaultViewModel.makeDevicesSettingsModel()?.isSectionVisible ?? false)
        XCTAssertTrue(model.isSectionVisible, "a configured build shows the section")
    }

    func testPairingNeedsTheManagementSession() async throws {
        harness.script.managementActive = false
        await model.pairDevice()
        let sheet = try XCTUnwrap(model.sheet)
        XCTAssertEqual(sheet.stage, .failed)
        XCTAssertEqual(sheet.message, "Unlock credential management to pair a device.")
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty, "nothing is created without the management session")
        await model.closeSheet()
        XCTAssertFalse(model.isSheetPresented)
    }

    func testTheCodeFieldAppearsOnlyAfterTheVerifiedReveal() async throws {
        await model.pairDevice()
        guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else { return XCTFail("the QR code") }
        XCTAssertNotNil(model.qrImage(for: text), "Core Image draws the QR code")
        XCTAssertEqual(model.sheet?.notice, "Scan only the QR code in this window. Never scan a QR code that someone sends you.")
        XCTAssertFalse(try XCTUnwrap(model.sheet).shownText.contains { $0.contains(text) }, "the payload is drawn, never written")

        try await harness.phone.scan(text)
        await harness.coordinator.refresh()
        let waiting = try XCTUnwrap(model.sheet)
        XCTAssertEqual(waiting.stage, .waitingForIPhone, "no field before the reveal")
        XCTAssertEqual(waiting.peer?.displayName, "Synthetic Phone")
        XCTAssertTrue(waiting.shownText.contains("iPhone (not verified)"), "the platform is never shown as verified")
        XCTAssertEqual(waiting.notice, "If the iPhone has shown a code for more than about 10 seconds while this window still waits, cancel and pair again.")
        model.codeEntry = "123456"
        XCTAssertFalse(model.canConfirm)
        await model.confirm()
        XCTAssertEqual(model.sheet?.stage, .waitingForIPhone, "an entry before the reveal is not taken")

        try await harness.phone.poll()
        await harness.coordinator.refresh()
        XCTAssertEqual(model.sheet?.stage, .codeEntry(accepted: false))
        XCTAssertEqual(model.sheet?.message, PairingSheetPresentation.codeInstruction)
        await model.closeSheet()
    }

    func testAWrongCodeAsksForNoAuthenticationAndCountsOneAttempt() async throws {
        let code = try await reachCodeEntry()
        model.codeEntry = "12 34"
        await model.confirm()
        XCTAssertEqual(model.sheet?.feedback, "Enter the six half-width digits shown on the iPhone.")
        XCTAssertEqual(model.codeEntry, "12 34", "a malformed entry stays for correcting and is not counted")
        guard case .enteringCode(_, 3) = harness.coordinator.pairing else { return XCTFail("still three attempts") }

        model.codeEntry = Self.wrong(code)
        await model.confirm()
        XCTAssertEqual(model.sheet?.feedback, "That code doesn't match. 2 attempts left.")
        XCTAssertEqual(model.sheet?.feedbackIsWarning, true)
        XCTAssertEqual(model.codeEntry, "")
        guard case .enteringCode(_, 2) = harness.coordinator.pairing else { return XCTFail("one attempt counted") }
        model.codeEntry = Self.wrong(code)
        await model.confirm()
        XCTAssertEqual(model.sheet?.feedback, "That code doesn't match. 1 attempt left.")
        XCTAssertTrue(harness.script.authenticationReasons.isEmpty, "a wrong code asks for no authentication")
        XCTAssertTrue(harness.macConfirmations().isEmpty)
        await model.closeSheet()
    }

    func testAMatchingCodeNeedsAuthenticationACancelStoresNothingAndARetryNeedsNoNewEntry() async throws {
        let code = try await reachCodeEntry()
        harness.script.authenticationResults = [.cancelled, .failed]
        model.codeEntry = code

        await model.confirm()
        XCTAssertEqual(harness.script.authenticationReasons, [ManagementAuthenticationAction.pairDevice.reasonKey],
                       "the matching code asks for system authentication with the pairing reason at once")
        XCTAssertEqual(model.sheet?.stage, .codeEntry(accepted: true))
        XCTAssertEqual(model.sheet?.feedback, "System authentication was cancelled. Nothing was sent; you can confirm again.")
        XCTAssertEqual(model.codeEntry, "", "the accepted entry is not shown again")
        XCTAssertTrue(model.canConfirm, "confirming again needs no new entry")
        XCTAssertTrue(harness.macConfirmations().isEmpty)
        XCTAssertTrue(harness.coordinator.devices.isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices], "a cancelled authentication stores nothing")

        await model.confirm()
        XCTAssertEqual(model.sheet?.feedback, "System authentication didn't succeed. Nothing was sent; you can confirm again.")
        XCTAssertTrue(harness.macConfirmations().isEmpty)

        await model.confirm()
        XCTAssertEqual(harness.script.authenticationReasons.count, 3)
        XCTAssertEqual(model.sheet?.stage, .waitingForIPhoneConfirmation)
        XCTAssertEqual(harness.macConfirmations().count, 1)
        try await harness.phone.confirm()
        try await harness.phone.poll()
        await harness.coordinator.refresh()
        XCTAssertEqual(model.sheet?.stage, .paired)
        XCTAssertEqual(harness.coordinator.devices.count, 1)
        await model.closeSheet()
        XCTAssertEqual(harness.coordinator.devices.count, 1, "Done keeps the device")
    }

    func testThreeWrongCodesExpiryAndASecondResponderStoreNothing() async throws {
        let code = try await reachCodeEntry()
        for _ in 0..<3 {
            model.codeEntry = Self.wrong(code)
            await model.confirm()
        }
        XCTAssertEqual(model.sheet?.stage, .ended(canPairAgain: true))
        XCTAssertEqual(model.sheet?.message, "The code didn't match three times, so this pairing ended. Nothing was stored. Pair again to get a new QR code.")

        await model.pairAgain()
        guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else { return XCTFail("a new QR code") }
        XCTAssertTrue(model.isSheetPresented)
        harness.clock.advance(by: 11 * 60)
        await harness.coordinator.refresh()
        XCTAssertEqual(model.sheet?.message, "The pairing session expired. Nothing was stored. Pair again to get a new QR code.")

        await model.pairAgain()
        guard case .qrCode(let second, _) = try XCTUnwrap(model.sheet).stage else { return XCTFail("a new QR code") }
        XCTAssertNotEqual(second, text)
        let other = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.phone.scan(second)
        try await other.scan(second, name: "Synthetic Other Phone")
        await harness.coordinator.refresh()
        XCTAssertEqual(model.sheet?.message, "A second device answered this QR code, so this pairing ended. Nothing was stored. Pair again, and make sure nobody else can see the QR code.")

        XCTAssertTrue(harness.coordinator.devices.isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
        XCTAssertTrue(harness.script.authenticationReasons.isEmpty)
        await model.closeSheet()
    }

    func testTheSheetNeverShowsTheMacsCode() async throws {
        var shown: [String] = []
        func record() { shown += model.sheet?.shownText ?? []; shown.append(model.codeEntry) }
        await model.pairDevice()
        record()
        guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else { return XCTFail("the QR code") }
        try await harness.phone.scan(text)
        await harness.coordinator.refresh()
        record()
        try await harness.phone.poll()
        await harness.coordinator.refresh()
        record()
        let shownCode = await harness.phone.shownCode()
        let code = try XCTUnwrap(shownCode)
        model.codeEntry = Self.wrong(code)
        await model.confirm()
        record()
        harness.script.authenticationResults = [.cancelled]
        model.codeEntry = code
        await model.confirm()
        record()
        await model.confirm()
        record()
        try await harness.phone.confirm()
        try await harness.phone.poll()
        await harness.coordinator.refresh()
        record()

        let digits = code.replacingOccurrences(of: " ", with: "")
        for text in shown {
            XCTAssertFalse(text.contains(digits) || text.contains(code), "the sheet shows the code: \(text)")
        }
        await model.closeSheet()
    }

    func testRemoveAsksForConfirmationFirst() async throws {
        try await harness.pairPhone()
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        model.requestRemoval(row)
        XCTAssertEqual(model.removalCandidate, row.id)
        XCTAssertEqual(harness.coordinator.devices.count, 1, "asking removes nothing")
        XCTAssertEqual(DevicesPresentation.removalWarning(row.displayName),
                       "This Mac stops trusting “Synthetic Phone” at once. Ask Key also tells the device, which removes this Mac the next time it connects.")
        model.cancelRemoval()
        await model.confirmRemoval()
        XCTAssertEqual(harness.coordinator.devices.count, 1, "a cancelled confirmation removes nothing")

        model.requestRemoval(row)
        await model.confirmRemoval()
        XCTAssertTrue(harness.coordinator.devices.isEmpty)
        XCTAssertNil(model.removalCandidate)
        XCTAssertEqual(harness.macSent(.unpairNotice).count, 1)
    }

    func testRenameTestDeliveryAndRowText() async throws {
        try await harness.pairPhone()
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        XCTAssertTrue(DevicesPresentation.rowSummary(row).hasPrefix("iPhone · Paired "))
        XCTAssertTrue(DevicesPresentation.rowStatus(row).text.hasPrefix("Last reached "))
        XCTAssertTrue(DevicesPresentation.rowStatus(row).text.hasSuffix(" · Delivery check answered"))

        model.beginRename(row)
        model.renameDraft = " \u{202E} "
        XCTAssertFalse(model.canSaveRename, "a name that cleans to nothing can't be saved")
        model.renameDraft = "Work iPhone"
        await model.saveRename()
        XCTAssertNil(model.renaming)
        XCTAssertEqual(harness.coordinator.devices.first?.displayName, "Work iPhone")

        let checks = harness.macSent(.deliveryCheck).count
        await model.testDelivery(try XCTUnwrap(harness.coordinator.devices.first))
        XCTAssertEqual(harness.macSent(.deliveryCheck).count, checks + 1)
        XCTAssertTrue(DevicesPresentation.rowStatus(try XCTUnwrap(harness.coordinator.devices.first)).text
            .hasSuffix(" · Delivery check sent"))

        harness.backend.accountState = .noAccount
        await harness.coordinator.devicesOpened()
        XCTAssertFalse(model.canTestDelivery, "no delivery check without the account")
        XCTAssertEqual(DevicesPresentation.rowStatus(try XCTUnwrap(harness.coordinator.devices.first)),
                       .init(text: "Can't be reached", isWarning: true))

        harness.script.managementActive = false
        model.beginRename(try XCTUnwrap(harness.coordinator.devices.first))
        model.renameDraft = "Locked Rename"
        await model.saveRename()
        XCTAssertEqual(harness.coordinator.lastIssue, .managementRequired)
        XCTAssertEqual(DevicesPresentation.issueMessage(.managementRequired),
                       "Credential management is locked. Unlock it, then try again.")
        XCTAssertEqual(harness.coordinator.devices.first?.displayName, "Work iPhone")
    }

    func testAnUnusableIdentityOffersAResetThatAsksFirst() async throws {
        try await harness.pairPhone()
        harness.backend.restoreFails = true
        await harness.relaunch()
        model = DevicesSettingsModel(coordinator: harness.coordinator)
        XCTAssertEqual(harness.coordinator.availability, .identityUnusable)
        XCTAssertTrue(model.offersReset)
        XCTAssertFalse(model.canPair)
        XCTAssertEqual(model.notice, .init(text: "This Mac's device keys no longer work, for example after Migration Assistant or a restore. Reset the device identity, then pair your devices again.", isWarning: true))

        model.requestReset()
        XCTAssertTrue(model.confirmingReset)
        XCTAssertFalse(harness.library.keys.deviceItems.isEmpty, "asking deletes nothing")
        model.cancelReset()
        await model.confirmReset()
        XCTAssertEqual(harness.coordinator.availability, .identityUnusable, "a cancelled confirmation deletes nothing")

        model.requestReset()
        await model.confirmReset()
        XCTAssertEqual(harness.coordinator.availability, .ready)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty, "the reset deletes the keys and the list")
        XCTAssertFalse(model.offersReset)
        XCTAssertTrue(model.canPair)
    }

    func testEachUnavailableStateShowsItsMessage() async throws {
        harness.backend.accountState = .noAccount
        await model.pairDevice()
        XCTAssertEqual(model.sheet?.stage, .failed)
        let signedOut = "iCloud is signed out, so paired devices can't be reached and pairing can't start. Sign in with the same Apple Account as your iPhone."
        XCTAssertEqual(model.sheet?.message, signedOut)
        XCTAssertEqual(model.notice, .init(text: signedOut, isWarning: true))
        await model.closeSheet()
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty, "no key is stored without an account")

        harness.backend.isSecureEnclaveAvailable = false
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-1")
        await model.pairDevice()
        XCTAssertEqual(model.sheet?.message, "This Mac has no Secure Enclave, so it can't keep device keys safe and can't pair.")
        await model.closeSheet()
        XCTAssertFalse(model.canPair)

        func notice(_ availability: DeviceServicesAvailability, _ account: DeviceAccountStatus = .available,
                    count: Int = 1, storage: String? = nil) -> DevicesPresentation.Notice {
            DevicesPresentation.sectionNotice(availability: availability, account: account, deviceCount: count,
                                              storageFailureMessage: storage)
        }
        let states: [(DevicesPresentation.Notice, String)] = [
            (notice(.secureEnclaveUnavailable), "This Mac has no Secure Enclave, so it can't keep device keys safe and can't pair."),
            (notice(.ready, .noAccount), signedOut),
            (notice(.ready, .restricted), "iCloud is restricted on this Mac, for example by Screen Time or a device management profile, so devices can't be reached."),
            (notice(.ready, .temporarilyUnavailable), "Ask Key can't reach iCloud right now, so devices can't be reached. Check the connection."),
            (notice(.ready, .accountChanged), "This Mac now uses a different Apple Account than the one these devices were paired in, so they can't be reached. Sign back in, or remove them and pair again."),
            (notice(.identityUnusable), "This Mac's device keys no longer work, for example after Migration Assistant or a restore. Reset the device identity, then pair your devices again."),
            (notice(.listRefused), "The list of paired devices failed its integrity check, so Ask Key won't use it. Reset the device identity, then pair your devices again."),
            (notice(.storageUnavailable, storage: "Synthetic keychain message."), "Synthetic keychain message."),
            (notice(.ready, count: PairedDeviceList.maximumCount), "8 devices are paired, the most Ask Key allows. Remove one to pair another."),
        ]
        for (notice, text) in states {
            XCTAssertEqual(notice, .init(text: text, isWarning: true))
        }
        XCTAssertFalse(notice(.ready).isWarning)
        XCTAssertFalse(DevicesPresentation.canPair(availability: .ready, account: .available,
                                                   deviceCount: PairedDeviceList.maximumCount, isPairing: false))
        XCTAssertFalse(DevicesPresentation.canPair(availability: .ready, account: .accountChanged, deviceCount: 1, isPairing: false))
        XCTAssertTrue(DevicesPresentation.canPair(availability: .ready, account: .noAccount, deviceCount: 0, isPairing: false),
                      "signing in again can be retried from Pair a Device…")
    }

    func testEveryEndAndStartFailureHasItsOwnMessage() {
        let reasons: [PairingEndReason] = [.cancelled, .codeMismatch, .commitmentMismatch, .cancelledByPeer, .undoneByPeer,
                                           .secondRequest, .expired, .deviceLimitReached, .keyConflict, .peerRemoved,
                                           .identityUnusable]
        XCTAssertEqual(Set(reasons.map(PairingSheetPresentation.endMessage)).count, reasons.count)
        let failures: [PairingStartFailure] = [.managementRequired, .secureEnclaveUnavailable, .accountUnavailable(.noAccount),
                                               .accountUnavailable(.restricted), .iCloudUnavailable, .identityUnusable,
                                               .storageUnavailable, .keyCreationFailed]
        XCTAssertEqual(Set(failures.map(PairingSheetPresentation.startFailureMessage)).count, failures.count)
    }

    // MARK: Support

    private func reachCodeEntry() async throws -> String {
        await model.pairDevice()
        guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else {
            XCTFail("the QR code")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        try await harness.phone.scan(text)
        await harness.coordinator.refresh()
        try await harness.phone.poll()
        await harness.coordinator.refresh()
        XCTAssertEqual(model.sheet?.stage, .codeEntry(accepted: false))
        let shownCode = await harness.phone.shownCode()
        return try XCTUnwrap(shownCode)
    }

    private static func wrong(_ code: String) -> String {
        let digits = code.replacingOccurrences(of: " ", with: "")
        return String(format: "%06d", (Int(digits)! + 1) % 1_000_000)
    }
}
