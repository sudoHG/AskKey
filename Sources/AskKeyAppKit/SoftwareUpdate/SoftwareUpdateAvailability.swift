import Foundation
import AskKeyBroker

/// Decides whether this process may create an in-app updater (ADR 0011).
///
/// Only a `Release` build qualifies: it is the only mode whose Info.plist
/// carries the feed URL. The bundle must also be the production bundle at the
/// official install path, and no testing flag may be present. Anything else
/// creates no Sparkle object and shows no update controls.
package enum SoftwareUpdateAvailability {
    /// A product identifier: every installed copy keeps requesting this URL.
    package static let feedURL = "https://askkey.sudohg.com/appcast.xml"
    package static let feedURLKey = "SUFeedURL"
    package static let bundleIdentifierKey = "CFBundleIdentifier"
    /// Only the testing modes write Info.plist keys with this prefix: `Local`
    /// writes `AskKeyLocalTesting`, Debug writes `AskKeyRequiresDebugRunDirectory`
    /// and E2E writes its own testing flag, which the release binary must not
    /// name. Any such key disables the updater, whatever its value.
    package static let testingFlagPrefix = "AskKey"

    package static func isEnabled(
        infoDictionary: [String: Any],
        topology: OfficialInstallDecision
    ) -> Bool {
        guard infoDictionary[feedURLKey] as? String == feedURL else { return false }
        guard infoDictionary[bundleIdentifierKey] as? String
            == OfficialInstallTopology.productionBundleIdentifier else { return false }
        guard !infoDictionary.keys.contains(where: { $0.hasPrefix(testingFlagPrefix) }) else { return false }
        // `developmentAccepted` also allows the runtime, but only for a
        // development build, which never updates itself.
        guard case .accepted = topology else { return false }
        return true
    }
}
