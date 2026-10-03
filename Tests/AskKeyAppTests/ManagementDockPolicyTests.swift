import AppKit
import XCTest
@testable import AskKeyApp

final class ManagementDockPolicyTests: AskKeyAppTestCase {
    func testLoginLaunchStaysAccessoryUntilTheUserOpensManagement() {
        var policy = ManagementDockPolicy()

        XCTAssertNil(policy.handle(.launch(isActive: false)))
        XCTAssertEqual(policy.activationPolicy, .accessory)
        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertEqual(policy.activationPolicy, .accessory)

        XCTAssertEqual(policy.handle(.managementWindowOpenedByUser), .regular)
        XCTAssertTrue(policy.isManagementWindowForeground)
    }

    func testActiveManagementWindowShowsDockOnceAndIgnoresDuplicateEvents() {
        var policy = ManagementDockPolicy()

        XCTAssertEqual(policy.handle(.launch(isActive: true)), .regular)
        XCTAssertNil(policy.handle(.launch(isActive: true)))
        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: false,
            key: true,
            applicationActive: true
        )))
        XCTAssertEqual(policy.activationPolicy, .regular)
        XCTAssertTrue(policy.isManagementWindowForeground)
    }

    func testResignMiniaturizeCloseAndHideReturnToAccessoryAndCanRecover() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: true))

        XCTAssertEqual(policy.handle(.applicationDidResignActive), .accessory)
        XCTAssertNil(policy.handle(.applicationDidResignActive))
        XCTAssertEqual(policy.handle(.applicationDidBecomeActive), .regular)

        XCTAssertEqual(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: true,
            key: false,
            applicationActive: true
        )), .accessory)
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: true,
            key: false,
            applicationActive: true
        )))

        XCTAssertEqual(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: false,
            key: true,
            applicationActive: true
        )), .regular)
        XCTAssertEqual(policy.handle(.managementWindowState(
            visible: false,
            miniaturized: false,
            key: false,
            applicationActive: true
        )), .accessory)
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: false,
            miniaturized: false,
            key: false,
            applicationActive: true
        )))
    }

    func testApprovalOrPopoverCannotRestoreDockFromHiddenManagementWindow() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: true))
        _ = policy.handle(.managementWindowState(
            visible: false,
            miniaturized: false,
            key: false,
            applicationActive: false
        ))

        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertFalse(policy.isManagementWindowForeground)
        XCTAssertEqual(policy.activationPolicy, .accessory)
    }

    func testApprovalWindowWithManagementVisibleButNotKeyStaysAccessory() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: true))

        XCTAssertEqual(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: false,
            key: false,
            applicationActive: true
        )), .accessory)
        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertFalse(policy.isManagementWindowForeground)
        XCTAssertEqual(policy.activationPolicy, .accessory)
    }

    func testStaleSettingsKeySnapshotAfterResignActiveStaysAccessory() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: true))
        XCTAssertEqual(policy.handle(.applicationDidResignActive), .accessory)

        XCTAssertNil(policy.handle(.managementWindowState(
            visible: true,
            miniaturized: false,
            key: true,
            applicationActive: false
        )))
        XCTAssertEqual(policy.activationPolicy, .accessory)
        XCTAssertFalse(policy.isManagementWindowForeground)
    }
}
