import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

final class InboxPollingTests: XCTestCase {
    func testTokenAdvancesOnlyWhenEveryMessageSettledAndAnExpiredTokenLeadsToAFullFetch() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let settledToken = try await XCTUnwrapAsync(await phone.messenger.inboxToken)

        harness.transport.expireChangeTokens(of: phone.id)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let report = try await phone.poll()
        XCTAssertEqual(report.processed, 1, "the full fetch from no token found the check")
        let refetchedToken = try await XCTUnwrapAsync(await phone.messenger.inboxToken)
        XCTAssertNotEqual(refetchedToken, settledToken)
        XCTAssertTrue(harness.transport.records(in: phone.id).isEmpty)
        await XCTAssertNotNilAsync(try await phone.entry(for: mac), "the list is kept")
    }

    func testMessageThatFailsThreeTimesIsRefusedAndDeleted() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let token = await phone.messenger.inboxToken
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        phone.store.failNextSaves(3)
        for attempt in 1...2 {
            let report = try await phone.poll()
            XCTAssertEqual(report.failed, 1, "attempt \(attempt)")
            XCTAssertEqual(harness.transport.records(in: phone.id).count, 1, "kept for the next poll")
            await XCTAssertEqualAsync(await phone.messenger.inboxToken, token, "the token stays behind the failed message")
        }
        let last = try await phone.poll()
        XCTAssertEqual(last.refusals, [.repeatedFailure])
        XCTAssertTrue(harness.transport.records(in: phone.id).isEmpty)
        await XCTAssertNotEqualAsync(await phone.messenger.inboxToken, token)
    }

    func testHeldMessageKeepsTheToken() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        harness.transport.delaying(.pairingReveal)
        try await mac.poll()
        try await phone.poll()
        try await phone.confirm()
        // The phone's confirmation overtakes its reveal.
        let tokenBefore = await mac.messenger.inboxToken
        let early = try await mac.poll()
        XCTAssertEqual(early.held, 1)
        await XCTAssertEqualAsync(await mac.messenger.inboxToken, tokenBefore)
        guard case .waitingForResponder = await mac.phase() else { return XCTFail("no code before the reveal") }
        harness.transport.releaseDelayed()
        let later = try await mac.poll()
        XCTAssertEqual(later.processed, 2)
        guard case .enteringCode = await mac.phase() else {
            return XCTFail("the held confirmation counts once the reveal arrives; the Mac still asks for the code")
        }
        try await mac.confirm()
        guard case .paired = await mac.phase() else { return XCTFail("both confirmations are held") }
    }
}
