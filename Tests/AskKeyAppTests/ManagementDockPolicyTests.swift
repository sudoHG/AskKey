import AppKit
import XCTest
@testable import AskKeyAppKit

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

    func testManagementOwnedDialogKeepsDockWhileManagementIsNotKey() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: true))
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: true, miniaturized: false, key: false,
            applicationActive: true, ownedDialog: true
        )))
        XCTAssertTrue(policy.isManagementWindowForeground)
        XCTAssertEqual(policy.activationPolicy, .regular)
        XCTAssertEqual(policy.handle(.applicationDidResignActive), .accessory)
        XCTAssertEqual(policy.handle(.applicationDidBecomeActive), .regular)

        XCTAssertEqual(policy.handle(.managementWindowState(
            visible: true, miniaturized: false, key: false,
            applicationActive: true, ownedDialog: false
        )), .accessory)
    }

    func testReturningFromDialogToManagementKeepsDockWithoutAnotherTransition() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.managementWindowOpenedByUser)
        _ = policy.handle(.managementWindowState(
            visible: true, miniaturized: false, key: false,
            applicationActive: true, ownedDialog: true
        ))
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: true, miniaturized: false, key: true,
            applicationActive: true, ownedDialog: false
        )))
        XCTAssertTrue(policy.isManagementWindowForeground)
    }

    func testOwnedDialogDoesNotKeepHiddenOrMiniaturizedManagementForeground() {
        for (visible, miniaturized) in [(false, false), (true, true)] {
            var policy = ManagementDockPolicy()
            _ = policy.handle(.launch(isActive: true))
            XCTAssertEqual(policy.handle(.managementWindowState(
                visible: visible, miniaturized: miniaturized, key: false,
                applicationActive: true, ownedDialog: true
            )), .accessory)
            XCTAssertFalse(policy.isManagementWindowForeground)
        }
    }

    func testFallbackKeepsItsCarrierAcrossWindowAndActivationChangesUntilCleanup() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: false))
        XCTAssertEqual(policy.handle(.lockedApprovalReminderFallbackChanged(true)), .regular)
        XCTAssertNil(policy.handle(.lockedApprovalReminderFallbackChanged(true)))
        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertNil(policy.handle(.applicationDidResignActive))
        XCTAssertNil(policy.handle(.managementWindowState(
            visible: false, miniaturized: false, key: false, applicationActive: false
        )))
        XCTAssertFalse(policy.isManagementWindowForeground)
        XCTAssertTrue(policy.lockedApprovalReminderFallbackVisible)

        // Queue empty, screen unlock, and detailed presentation share this reset.
        XCTAssertEqual(policy.handle(.lockedApprovalReminderFallbackChanged(false)), .accessory)
        XCTAssertFalse(policy.lockedApprovalReminderFallbackVisible)
        XCTAssertNil(policy.handle(.lockedApprovalReminderFallbackChanged(false)))
    }

    func testFallbackCleanupPreservesForegroundManagementOrItsDialog() {
        for dialog in [false, true] {
            var policy = ManagementDockPolicy()
            _ = policy.handle(.managementWindowOpenedByUser)
            _ = policy.handle(.lockedApprovalReminderFallbackChanged(true))
            _ = policy.handle(.managementWindowState(
                visible: true, miniaturized: false, key: !dialog,
                applicationActive: true, ownedDialog: dialog
            ))
            XCTAssertNil(policy.handle(.lockedApprovalReminderFallbackChanged(false)))
            XCTAssertEqual(policy.activationPolicy, .regular)
            XCTAssertFalse(policy.lockedApprovalReminderFallbackVisible)
            XCTAssertEqual(policy.handle(.applicationDidResignActive), .accessory)
        }
    }

    func testOnlyUnavailableOrFailedNotificationsNeedTheFallbackCarrier() {
        var policy = ManagementDockPolicy()
        _ = policy.handle(.launch(isActive: false))
        for result in [LockedApprovalReminderDeliveryResult.authorizationUnavailable, .deliveryFailed] {
            let posted = LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: result)
            XCTAssertEqual(policy.handle(.lockedApprovalReminderFallbackChanged(!posted)), .regular)
            XCTAssertEqual(policy.handle(.lockedApprovalReminderFallbackChanged(false)), .accessory)
        }
        let posted = LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .delivered)
        XCTAssertNil(policy.handle(.lockedApprovalReminderFallbackChanged(!posted)))
        XCTAssertEqual(policy.activationPolicy, .accessory)
    }

    func testWriteFailureNeedsTheDockOnlyWhenNotificationDeliveryFails() {
        for result in [LockedApprovalReminderDeliveryResult.authorizationUnavailable, .deliveryFailed, .delivered] {
            var policy = ManagementDockPolicy()
            let attempt = UUID()
            XCTAssertNil(policy.handle(.agentWriteFailureStarted(attempt)))
            XCTAssertEqual(policy.handle(.agentWriteFailureDeliveryFinished(attempt, result)), result == .delivered ? nil : .regular)
            XCTAssertEqual(policy.agentWriteFailureFallbackVisible, result != .delivered)
            XCTAssertFalse(policy.isManagementWindowForeground, "A reminder never marks management active or visible")
            XCTAssertFalse(policy.applicationActive)
            XCTAssertFalse(policy.managementWindowVisible)
        }
    }

    func testWriteFailureSurvivesApprovalCleanupAndBackgroundEventsUntilAcknowledged() {
        var policy = ManagementDockPolicy()
        let attempt = UUID()
        _ = policy.handle(.agentWriteFailureStarted(attempt))
        _ = policy.handle(.agentWriteFailureDeliveryFinished(attempt, .deliveryFailed))
        XCTAssertNil(policy.handle(.applicationDidBecomeActive))
        XCTAssertNil(policy.handle(.applicationDidResignActive))
        XCTAssertNil(policy.handle(.managementWindowState(visible: false, miniaturized: false, key: false, applicationActive: false)))
        _ = policy.handle(.lockedApprovalReminderFallbackChanged(true))
        XCTAssertNil(policy.handle(.lockedApprovalReminderFallbackChanged(false)))
        XCTAssertEqual(policy.activationPolicy, .regular)
        XCTAssertEqual(policy.handle(.agentWriteFailureAcknowledged), .accessory)
        XCTAssertNil(policy.agentWriteFailureReminder)
        XCTAssertFalse(policy.agentWriteFailureFallbackVisible)
        XCTAssertNil(policy.handle(.agentWriteFailureDeliveryFinished(attempt, .deliveryFailed)))
        XCTAssertEqual(policy.activationPolicy, .accessory, "A late callback cannot resurrect an acknowledged failure")
    }

    func testOpeningManagementClearsWriteFailureAndInvalidatesItsPendingCallback() {
        for completeFirst in [false, true] {
            var policy = ManagementDockPolicy()
            let attempt = UUID()
            _ = policy.handle(.agentWriteFailureStarted(attempt))
            if completeFirst { _ = policy.handle(.agentWriteFailureDeliveryFinished(attempt, .authorizationUnavailable)) }
            _ = policy.handle(.managementWindowOpenedByUser)
            XCTAssertFalse(policy.agentWriteFailureFallbackVisible)
            XCTAssertNil(policy.agentWriteFailureReminder)
            XCTAssertNil(policy.handle(.agentWriteFailureDeliveryFinished(attempt, .authorizationUnavailable)))
            XCTAssertEqual(policy.handle(.applicationDidResignActive), .accessory)
        }
    }

    func testWriteFailureCleanupPreservesIndependentLockedReminderAndForegroundManagement() {
        for foreground in [false, true] {
            var policy = ManagementDockPolicy()
            let attempt = UUID()
            _ = policy.handle(.agentWriteFailureStarted(attempt))
            _ = policy.handle(.agentWriteFailureDeliveryFinished(attempt, .deliveryFailed))
            if foreground { _ = policy.handle(.managementWindowOpenedByUser) }
            else { _ = policy.handle(.lockedApprovalReminderFallbackChanged(true)) }
            XCTAssertNil(policy.handle(.agentWriteFailureAcknowledged))
            XCTAssertEqual(policy.activationPolicy, .regular)
            XCTAssertFalse(policy.agentWriteFailureFallbackVisible)
        }
    }

    func testSupersededWriteFailureCallbackIsIgnoredButExistingFallbackStaysUntilAcknowledgement() {
        var policy = ManagementDockPolicy()
        let first = UUID(), second = UUID()
        _ = policy.handle(.agentWriteFailureStarted(first))
        _ = policy.handle(.agentWriteFailureStarted(second))
        XCTAssertNil(policy.handle(.agentWriteFailureDeliveryFinished(first, .deliveryFailed)))
        XCTAssertFalse(policy.agentWriteFailureFallbackVisible)
        XCTAssertEqual(policy.handle(.agentWriteFailureDeliveryFinished(second, .deliveryFailed)), .regular)
        _ = policy.handle(.agentWriteFailureStarted(UUID()))
        XCTAssertTrue(policy.agentWriteFailureFallbackVisible)
        XCTAssertEqual(policy.handle(.agentWriteFailureAcknowledged), .accessory)
    }
}
