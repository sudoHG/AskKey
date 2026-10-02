import Foundation
import XCTest
@testable import AskKeyApp

final class ManualUpdatePolicyTests: XCTestCase {
    func testOfficialPolicyKeepsManualUpdaterLifecycleAndDisablesAutoCycles() {
        let policy = ManualUpdatePolicy.official
        XCTAssertTrue(policy.startsUpdater)
        XCTAssertFalse(policy.automaticallyChecksForUpdates)
        XCTAssertFalse(policy.automaticallyDownloadsUpdates)
        XCTAssertFalse(policy.allowsAutomaticUpdates)
        XCTAssertFalse(policy.promptsForAutomaticCheckPermission)
    }

    func testExistingAutomaticPreferencesCannotOptBackIntoTheForbiddenCycle() {
        XCTAssertEqual(
            ManualUpdatePolicy.afterExistingPreferences(
                automaticChecksEnabled: true,
                automaticDownloadsEnabled: true
            ),
            .official
        )
        let defaults = UserDefaults(suiteName: "askkey.manual-update.\(UUID().uuidString)") ?? .standard
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        defaults.set(true, forKey: "SUAllowsAutomaticUpdates")
        ManualUpdatePolicy.applyEnforcedDefaults(defaults)
        XCTAssertEqual(defaults.bool(forKey: "SUEnableAutomaticChecks"), false)
        XCTAssertEqual(defaults.bool(forKey: "SUAutomaticallyUpdate"), false)
        XCTAssertEqual(defaults.bool(forKey: "SUAllowsAutomaticUpdates"), false)
    }

    func testReleaseLaunchPlanStartsUpdaterWithoutAutomaticCycles() {
        let plan = SoftwareUpdaterLaunchPlan.make(isDevelopmentBuild: false)
        XCTAssertTrue(plan.createController)
        XCTAssertTrue(plan.startingUpdater)
        XCTAssertFalse(plan.automaticallyChecksForUpdates)
        XCTAssertFalse(plan.automaticallyDownloadsUpdates)
        XCTAssertFalse(plan.allowsAutomaticUpdates)
        XCTAssertFalse(plan.promptsForAutomaticCheckPermission)
    }

    func testDevelopmentLaunchPlanDoesNotCreateAProductionUpdater() {
        let plan = SoftwareUpdaterLaunchPlan.make(isDevelopmentBuild: true)
        XCTAssertFalse(plan.createController)
        XCTAssertFalse(plan.startingUpdater)
    }

    func testLocalTestingLaunchPlanDoesNotCreateAProductionUpdater() {
        let plan = SoftwareUpdaterLaunchPlan.make(isDevelopmentBuild: false, isLocalTesting: true)
        XCTAssertFalse(plan.createController)
        XCTAssertFalse(plan.startingUpdater)
    }

    func testSettingsCopyPromisesConfirmAfterCheckInsteadOfAutomaticChecks() {
        let subtitle = FrozenSettingsContract.softwareUpdateSubtitle(appVersion: "9.8.7")
        XCTAssertFalse(subtitle.contains("自动检查"))
        XCTAssertFalse(subtitle.localizedCaseInsensitiveContains("Automatically checks"))
        XCTAssertTrue(subtitle.contains("9.8.7"))
    }
}
