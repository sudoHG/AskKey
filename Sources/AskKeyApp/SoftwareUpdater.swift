import Foundation
import Sparkle
import AskKeyCore

struct ManualUpdatePolicy: Equatable, Sendable {
    var startsUpdater: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var allowsAutomaticUpdates: Bool
    var promptsForAutomaticCheckPermission: Bool

    static let official = ManualUpdatePolicy(
        startsUpdater: true,
        automaticallyChecksForUpdates: false,
        automaticallyDownloadsUpdates: false,
        allowsAutomaticUpdates: false,
        promptsForAutomaticCheckPermission: false
    )

    static func afterExistingPreferences(
        automaticChecksEnabled: Bool,
        automaticDownloadsEnabled: Bool
    ) -> ManualUpdatePolicy {
        official
    }

    static func enforcedUserDefaults(existing: [String: Any]) -> [String: Bool] {
        [
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false,
        ]
    }

    static func applyEnforcedDefaults(_ defaults: UserDefaults) {
        for (key, value) in enforcedUserDefaults(existing: defaults.dictionaryRepresentation()) {
            defaults.set(value, forKey: key)
        }
    }
}

struct SoftwareUpdaterLaunchPlan: Equatable, Sendable {
    var createController: Bool
    var startingUpdater: Bool
    var automaticallyChecksForUpdates: Bool
    var automaticallyDownloadsUpdates: Bool
    var allowsAutomaticUpdates: Bool
    var promptsForAutomaticCheckPermission: Bool

    static func make(
        isDevelopmentBuild: Bool,
        isLocalTesting: Bool = false,
        policy: ManualUpdatePolicy = .official
    ) -> Self {
        if isDevelopmentBuild || isLocalTesting {
            return Self(
                createController: false,
                startingUpdater: false,
                automaticallyChecksForUpdates: false,
                automaticallyDownloadsUpdates: false,
                allowsAutomaticUpdates: false,
                promptsForAutomaticCheckPermission: false
            )
        }
        return Self(
            createController: true,
            startingUpdater: policy.startsUpdater,
            automaticallyChecksForUpdates: policy.automaticallyChecksForUpdates,
            automaticallyDownloadsUpdates: policy.automaticallyDownloadsUpdates,
            allowsAutomaticUpdates: policy.allowsAutomaticUpdates,
            promptsForAutomaticCheckPermission: policy.promptsForAutomaticCheckPermission
        )
    }
}

/// Wraps Sparkle's updater so the menu-bar app can offer "Check for Updates…".
///
/// Sparkle needs a Developer ID-signed, notarized bundle with an embedded
/// `Sparkle.framework` and an `SUFeedURL` in Info.plist to work; only release
/// builds produce those. Development builds run from `swift build`/Xcode without
/// a feed URL, so the updater stays inert there and the UI hides its controls.
@Observable
@MainActor
final class SoftwareUpdater {
    @ObservationIgnored let controller: SPUStandardUpdaterController?
    @ObservationIgnored private let updateDelegate: ManualSparkleUpdateDelegate?

    init(
        isDevelopmentBuild: Bool = VaultConfiguration.isDevelopmentBuild,
        isLocalTesting: Bool = Bundle.main.object(forInfoDictionaryKey: "AskKeyLocalTesting") as? Bool == true,
        defaults: UserDefaults = .standard,
        policy: ManualUpdatePolicy = .official
    ) {
        let plan = SoftwareUpdaterLaunchPlan.make(
            isDevelopmentBuild: isDevelopmentBuild,
            isLocalTesting: isLocalTesting,
            policy: policy
        )
        guard plan.createController else {
            controller = nil
            updateDelegate = nil
            return
        }
        ManualUpdatePolicy.applyEnforcedDefaults(defaults)
        let delegate = ManualSparkleUpdateDelegate(policy: policy)
        updateDelegate = delegate
        let created = SPUStandardUpdaterController(
            startingUpdater: plan.startingUpdater,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        created.updater.automaticallyChecksForUpdates = plan.automaticallyChecksForUpdates
        created.updater.automaticallyDownloadsUpdates = plan.automaticallyDownloadsUpdates
        controller = created
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

private final class ManualSparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    let policy: ManualUpdatePolicy

    init(policy: ManualUpdatePolicy) {
        self.policy = policy
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        policy.promptsForAutomaticCheckPermission
    }
}
