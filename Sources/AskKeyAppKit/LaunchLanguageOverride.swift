import Foundation

/// Ask Key's own text follows `AppLanguage` and switches at runtime. AppKit
/// and the frameworks it loads (the main menu, the About panel, standard
/// alerts and panels, Sparkle's windows) localize from the process's preferred
/// languages instead, which the process reads once, at its first localized
/// lookup. So at launch, before anything is localized, an explicit language
/// choice goes first in that list; Follow System leaves it alone (#266).
///
/// The list goes into the argument domain, where a `-AppleLanguages` launch
/// argument would put it. That domain is volatile: nothing reaches the app's
/// defaults on disk, the override ends with the process, and Follow System,
/// which reads `AppLanguage.macOSPreferredLanguages()`, never sees it.
enum LaunchLanguageOverride {
    static let key = "AppleLanguages"

    /// The process's language list for a saved language mode, or nil to keep
    /// the macOS order.
    static func preferredLanguages(mode: String, macOSLanguages: [String]) -> [String]? {
        guard let profile = AppLanguage.profiles.first(where: { $0.published && $0.id == mode }) else {
            return nil
        }
        return [profile.catalogCode] + macOSLanguages.filter { $0 != profile.catalogCode }
    }

    struct ArgumentDomain {
        /// A `-AppleLanguages` launch argument, as the Touch ID helper process
        /// receives, already chose the language.
        var commandLineSetsLanguages: Bool
        var read: () -> [String: Any]
        var write: ([String: Any]) -> Void

        static var process: Self {
            Self(
                commandLineSetsLanguages: ProcessInfo.processInfo.arguments.contains("-" + key),
                read: { UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain) },
                write: { UserDefaults.standard.setVolatileDomain($0, forName: UserDefaults.argumentDomain) }
            )
        }
    }

    /// Call before anything loads a localized resource; a later call no
    /// longer changes AppKit's language for this process.
    static func apply(
        mode: String,
        macOSLanguages: [String] = AppLanguage.macOSPreferredLanguages(),
        to domain: ArgumentDomain = .process
    ) {
        guard !domain.commandLineSetsLanguages else { return }
        var values = domain.read()
        if let languages = preferredLanguages(mode: mode, macOSLanguages: macOSLanguages) {
            values[key] = languages
        } else if values.removeValue(forKey: key) == nil {
            return
        }
        domain.write(values)
    }
}
