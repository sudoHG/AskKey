import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

@MainActor
final class IdentityResetTests: XCTestCase {
    func testKeysThatNoLongerRestoreShowTheResetAndResetDeletesEverything() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        let phoneID = try world.phone.deviceID

        world.identities.restoringError = .unusable
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.stage, .unusableIdentity)

        await relaunched.resetIdentity()
        XCTAssertEqual(relaunched.stage, .welcome)
        XCTAssertEqual(relaunched.welcomeStep, .intro)
        XCTAssertTrue(world.keychain.accounts.isEmpty, "keys and list are deleted")
        XCTAssertNil(world.localState.inboxPosition)
        XCTAssertNil(world.localState.deviceID)
        XCTAssertEqual(world.cloud.removedInboxes, [phoneID], "the inbox is deleted using the stored device ID")
        XCTAssertTrue(relaunched.pairedMacs.isEmpty)
    }

    func testAKeyThatStopsWorkingWhileRunningShowsTheReset() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        let phone = try world.phone
        _ = try await world.mac.sendDeliveryCheck(to: phone.deviceID)
        phone.isUnusable = true
        await world.model.processInbox()
        XCTAssertEqual(world.model.stage, .unusableIdentity)

        await world.model.resetIdentity()
        XCTAssertEqual(world.model.stage, .welcome)
        XCTAssertTrue(world.keychain.accounts.isEmpty)
        XCTAssertEqual(world.cloud.removedInboxes, [phone.deviceID])
        XCTAssertTrue(world.model.deliveryRecords.isEmpty)

        world.identities.restoringError = nil
        await world.model.runWelcomeChecks()
        XCTAssertEqual(world.model.stage, .ready)
        XCTAssertNotEqual(try world.phone.deviceID, phone.deviceID, "pairing again starts from a new identity")
    }

    func testIncompleteStoredKeysAreUnusable() async throws {
        let world = TestWorld()
        try world.keychain.setData(Data([1]), for: "device-message-key")
        await world.model.start()
        XCTAssertEqual(world.model.stage, .unusableIdentity)
        await world.model.resetIdentity()
        XCTAssertEqual(world.model.stage, .welcome)
        XCTAssertTrue(world.keychain.accounts.isEmpty)
    }

    func testAStoredListThatDoesNotDecodeIsUnusable() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try world.keychain.setData(Data("not a list".utf8), for: "paired-devices")
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.stage, .unusableIdentity)
    }

    func testResetOnlyFromTheUnusableScreen() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        await world.model.resetIdentity()
        XCTAssertEqual(world.model.stage, .ready)
        XCTAssertEqual(world.keychain.accounts.count, 4)
    }
}
