import Foundation
import Observation

/// The in-app updater as the UI sees it (ADR 0011). Only the production
/// executable supplies one, backed by Sparkle, so this module, the tests, the
/// E2E app and the helper never link Sparkle.
@MainActor
package protocol SoftwareUpdater: AnyObject {
    /// False while a check or an update is already in progress.
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    /// Starts a user-initiated check that shows its own progress and result.
    func checkForUpdates()
    /// Calls `handler` whenever either property above changes.
    func observeChanges(_ handler: @escaping @MainActor () -> Void)
}

/// Creates the updater once `SoftwareUpdateAvailability` allows it. The gate
/// must decide every relaunch Sparkle asks for.
package typealias SoftwareUpdaterFactory = @MainActor (SoftwareUpdateRelaunchGate) -> any SoftwareUpdater

/// Observable state for the update controls in Settings and the status menu.
/// It exists only when an updater exists, so its absence hides every control.
@Observable
@MainActor
package final class SoftwareUpdateControls {
    package private(set) var canCheckForUpdates = false
    package private(set) var automaticallyChecksForUpdates = false
    @ObservationIgnored private let updater: any SoftwareUpdater

    package init(updater: any SoftwareUpdater) {
        self.updater = updater
        refresh()
        updater.observeChanges { [weak self] in self?.refresh() }
    }

    package func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        refresh()
    }

    package func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    private func refresh() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}
