import AppKit
import AskKeyAppKit
import Sparkle

/// Sparkle 2 behind the `SoftwareUpdater` interface (ADR 0011). AskKeyAppKit
/// decides whether this object exists; it only adapts Sparkle's standard
/// controller and routes every relaunch through the relaunch gate.
@MainActor
final class SparkleSoftwareUpdater: NSObject, SoftwareUpdater, SPUUpdaterDelegate {
    private let relaunchGate: SoftwareUpdateRelaunchGate
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    init(relaunchGate: SoftwareUpdateRelaunchGate) {
        self.relaunchGate = relaunchGate
        super.init()
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.userAgentString = Self.userAgent()
        self.controller = controller
        controller.startUpdater()
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        guard let updater = controller?.updater else { return }
        let notify: () -> Void = { Task { @MainActor in handler() } }
        observations = [
            updater.observe(\.canCheckForUpdates) { _, _ in notify() },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in notify() },
        ]
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        relaunchGate.postponeIfBusy(installHandler)
    }

    /// Sparkle's default user agent uses the localized display name and drops
    /// non-ASCII characters, so a Chinese interface would send "??". Keep the
    /// same format with the fixed English product name instead.
    static func userAgent(
        appInfo: [String: Any]? = Bundle.main.infoDictionary,
        sparkleInfo: [String: Any]? = Bundle(for: SPUUpdater.self).infoDictionary
    ) -> String {
        let appVersion = appInfo?["CFBundleShortVersionString"] as? String ?? "?"
        let sparkleVersion = sparkleInfo?["CFBundleShortVersionString"] as? String ?? "?"
        return "Ask Key/\(appVersion) Sparkle/\(sparkleVersion)"
    }
}
