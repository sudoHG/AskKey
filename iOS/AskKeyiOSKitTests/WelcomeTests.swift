import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

@MainActor
final class WelcomeTests: XCTestCase {
    private func failure(_ prepare: (TestWorld) -> Void) async -> (TestWorld, WelcomeStep) {
        let world = TestWorld()
        prepare(world)
        await world.model.start()
        XCTAssertEqual(world.model.stage, .welcome)
        await world.model.runWelcomeChecks()
        return (world, world.model.welcomeStep)
    }

    func testLaunchWithoutIdentityShowsWelcomeAndCreatesNoTransport() async {
        let world = TestWorld()
        await world.model.start()
        XCTAssertEqual(world.model.stage, .welcome)
        XCTAssertEqual(world.model.welcomeStep, .intro)
        XCTAssertTrue(world.factory.madeTransports.isEmpty)
        XCTAssertEqual(world.identities.createdCount, 0)
    }

    func testPassingChecksCreatesKeysListInboxAndAsksForNotifications() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        let phone = try world.phone
        XCTAssertEqual(world.identities.createdCount, 1)
        XCTAssertEqual(world.keychain.accounts, ["device-message-key", "device-agreement-key", "device-approval-key",
                                                 "paired-devices"])
        XCTAssertEqual(world.cloud.preparedDevices, [phone.deviceID])
        XCTAssertEqual(world.factory.madeTransports, [phone.deviceID])
        XCTAssertEqual(world.notifications.authorizationRequests, 1)
        XCTAssertEqual(world.localState.deviceID, phone.deviceID.text)
        XCTAssertEqual(world.localState.inboxPosition, InboxPosition(userRecordName: "_user-a", token: nil))
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
    }

    func testNoSecureEnclave() async {
        let (world, step) = await failure { $0.identities.isSecureEnclaveAvailable = false }
        XCTAssertEqual(step, .failed(.noSecureEnclave))
        XCTAssertTrue(world.factory.madeTransports.isEmpty)
    }

    func testEachBiometryFailureHasItsOwnExplanation() async {
        let cases: [(BiometryStatus, WelcomeFailure)] = [
            (.notEnrolled(.faceID), .biometryNotEnrolled(.faceID)),
            (.notEnrolled(.touchID), .biometryNotEnrolled(.touchID)),
            (.passcodeNotSet, .passcodeNotSet),
            (.deniedForApp(.faceID), .biometryDenied(.faceID)),
            (.unavailable, .noBiometry),
        ]
        for (status, expected) in cases {
            let (world, step) = await failure { $0.biometry.current = status }
            XCTAssertEqual(step, .failed(expected))
            XCTAssertEqual(world.identities.createdCount, 0, "no key before the checks pass")
            XCTAssertTrue(world.factory.madeTransports.isEmpty, "no container before the checks pass")
        }
    }

    func testBuildWithoutCloudKitNeverCreatesATransport() async {
        let (world, step) = await failure { $0.factory.isConfigured = false }
        XCTAssertEqual(step, .failed(.cloudNotConfigured))
        XCTAssertEqual(world.identities.createdCount, 0)
        XCTAssertTrue(world.factory.madeTransports.isEmpty)
    }

    func testEachICloudFailureHasItsOwnExplanationAndStoresNothing() async {
        let cases: [(CloudKitAccountState, WelcomeFailure)] = [
            (.noAccount, .iCloudSignedOut),
            (.restricted, .iCloudRestricted),
            (.temporarilyUnavailable, .iCloudUnavailable),
        ]
        for (state, expected) in cases {
            let (world, step) = await failure { $0.cloud.accountState = state }
            XCTAssertEqual(step, .failed(expected))
            XCTAssertTrue(world.keychain.accounts.isEmpty, "keys stay in memory until every check passed")
            XCTAssertEqual(world.notifications.authorizationRequests, 0)
        }
    }

    func testKeyCreationFailure() async {
        let (world, step) = await failure { $0.identities.createError = .keyCreationFailed }
        XCTAssertEqual(step, .failed(.keyCreationFailed))
        XCTAssertTrue(world.keychain.accounts.isEmpty)
    }

    func testKeychainFailureLeavesNoKeys() async {
        let (world, step) = await failure { $0.keychain.writesFail = true }
        XCTAssertEqual(step, .failed(.keychainFailed))
        XCTAssertTrue(world.keychain.accounts.isEmpty)
    }

    func testNetworkFailureKeepsTheIdentityAndRetryFinishesWithTheSameKeys() async throws {
        let (world, step) = await failure { $0.cloud.prepareError = .networkUnavailable }
        XCTAssertEqual(step, .failed(.networkUnavailable))
        XCTAssertEqual(world.keychain.accounts.count, 4)
        world.cloud.prepareError = nil
        await world.model.runWelcomeChecks()
        XCTAssertEqual(world.model.stage, .ready)
        XCTAssertEqual(world.identities.createdCount, 1, "a retry never creates new keys")
        XCTAssertEqual(world.cloud.preparedDevices, [try world.phone.deviceID])
    }

    func testOtherICloudFailuresAndPendingSubscriptions() async {
        let (_, quota) = await failure { $0.cloud.prepareError = .quotaExceeded }
        XCTAssertEqual(quota, .failed(.iCloudFailed))
        let (_, pending) = await failure { $0.cloud.prepareLeavesSubscriptionsPending = true }
        XCTAssertEqual(pending, .failed(.iCloudFailed))
    }

    func testLaunchWithIdentityRestoresItAndSkipsWelcome() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.stage, .ready)
        XCTAssertEqual(world.identities.createdCount, 1)
    }

    func testRetryAfterAnUnreadableKeychainRestoresAnExistingIdentityInsteadOfReplacingIt() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        let stored = world.keychain.accounts
        let relaunched = AppModel(environment: world.environment)
        relaunched.stage = .welcome
        relaunched.welcomeStep = .failed(.keychainFailed)
        await relaunched.runWelcomeChecks()
        XCTAssertEqual(relaunched.stage, .ready)
        XCTAssertEqual(world.identities.createdCount, 1)
        XCTAssertEqual(world.keychain.accounts, stored)
    }
}

final class CloudKitGateTests: XCTestCase {
    /// A bundle without `CloudKitContainerIdentifier`, like every build but
    /// the Ad Hoc export, never creates a container.
    func testABuildWithoutTheContainerKeyNeverCreatesATransport() {
        let factory = CloudKitTransportFactory(bundle: Bundle(for: CloudKitGateTests.self))
        XCTAssertFalse(factory.isConfigured)
        XCTAssertNil(factory.makeTransport(for: DeviceID(rawValue: Data(repeating: 1, count: 16))!))
    }
}
