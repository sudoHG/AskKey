import Foundation
import Observation

struct LanguageProfile: Sendable, Equatable {
    var id: String
    var catalogCode: String
    var formatLocaleIdentifier: String
    var titleKey: String
    var published: Bool
    var systemPrefixes: [String]
    var oneIsSingular: Bool

    func matchesSystem(_ language: String) -> Bool {
        let lowered = language.lowercased()
        return systemPrefixes.contains { prefix in
            lowered == prefix
                || lowered.hasPrefix(prefix + "-")
                || lowered.hasPrefix(prefix + "_")
        }
    }

    func pluralCategory(count: Int) -> String {
        if oneIsSingular && count == 1 {
            return "one"
        }
        return "other"
    }
}

struct CatalogProvenance: Sendable, Equatable {
    enum Source: String, Sendable {
        case compiledStrings
        case stringCatalog
        case empty
    }

    var language: String
    var source: Source
    var keyCount: Int
    var bundleURL: URL?
}

@MainActor
@Observable
final class AppLanguageStore {
    private(set) var mode: String
    private(set) var resolved: String

    var locale: Locale { AppLanguage.locale(for: resolved) }

    init(mode: String = "system") {
        self.mode = mode
        self.resolved = AppLanguage.resolve(mode: mode)
    }

    func apply(mode: String) {
        AppLanguage.apply(mode: mode)
    }

    fileprivate func adopt(mode: String, resolved: String) {
        self.mode = mode
        self.resolved = resolved
    }
}

enum AppLanguage {
    static let technicalName = "AskKey"
    static let technicalCommand = "askkey"
    static let ownershipSentinels = ["Ask Key", "Credential Library", "Settings"]

    /// Single declaration for resolve / catalog locale / format locale / settings / sync.
    static let profiles: [LanguageProfile] = [
        LanguageProfile(
            id: "zh-Hans",
            catalogCode: "zh-Hans",
            formatLocaleIdentifier: "zh_Hans",
            titleKey: "Chinese",
            published: true,
            systemPrefixes: ["zh"],
            oneIsSingular: false
        ),
        LanguageProfile(
            id: "en",
            catalogCode: "en",
            formatLocaleIdentifier: "en",
            titleKey: "English",
            published: true,
            systemPrefixes: ["en"],
            oneIsSingular: true
        ),
        LanguageProfile(
            id: "qps-ploc",
            catalogCode: "qps-ploc",
            formatLocaleIdentifier: "en",
            titleKey: "Pseudo-localization",
            published: false,
            systemPrefixes: ["qps"],
            oneIsSingular: true
        ),
    ]

    static var publishedModes: [String] {
        ["system"] + profiles.filter(\.published).map(\.id)
    }

    @MainActor static let store = AppLanguageStore()

    static var systemLanguages: () -> [String] = { Locale.preferredLanguages }

    private static let currentLock = NSLock()
    private static var currentStorage = "en"
    static var current: String {
        get {
            currentLock.lock(); defer { currentLock.unlock() }
            return currentStorage
        }
        set {
            currentLock.lock(); currentStorage = newValue; currentLock.unlock()
        }
    }

    static let requiredKeys = [
        "Ask Key",
        "Follow System",
        "Simplified Chinese",
        "English",
        "Language",
        "Confirm credential management",
        "Credential management requires confirmation before it can continue.",
        "System authentication is unavailable.",
        "System authentication failed.",
        "Ask Key could not access the vault. Allow Keychain access, then try again.",
        "Ask Key could not start Agent access because the secure staging folder is a file. Remove that file, then retry.",
        "Ask Key could not start Agent access because it cannot write the secure staging folder. Fix folder permissions, then retry.",
        "Ask Key could not start Agent access. Check the local Ask Key folder, then retry.",
        "Retry Agent access",
        "Reveal credential value",
        "Pause Agent access",
        "Resume Agent access",
        "Clear Ask Key access records",
        "Erase the local Ask Key vault",
        "Restore Ask Key encrypted backup",
        "Create a new Ask Key backup namespace",
        "Start Ask Key backup with the saved recovery key",
        "Take ownership of Ask Key iCloud backup",
        "Delete Ask Key iCloud backup",
        "View the frozen file submitted for approval",
        "Approve this Agent credential request",
        "Approve this Agent credential change",
        "Welcome to Ask Key",
        "Create or import your first credential to start.",
        "Create credential",
        "Import file or .env",
        "Three permission levels",
        "Allow: Agents can use this credential silently.",
        "Ask: Agents wait for your approval each time.",
        "Hidden: Hidden credentials stay out of the Agent catalog.",
        "New credentials default to Ask.",
        "Timed allow is global for this Mac user, defaults to 30 minutes, and can be changed in Settings. It only covers reads; writes still need approval every time.",
        "Codex",
        "Cursor",
        "Grok CLI",
        "Launch at login is on by default so Agents can reach Ask Key.",
        "Continue",
        "CLI and MCP cannot obtain credentials while Ask Key is not running.",
        "Turn Off Launch at Login",
        "Keep Launch at Login",
        "Ask Key has pending requests",
        "Unlock your Mac to review a pending request.",
        "Open Ask Key to review pending requests.",
        "Disable system authentication for read approvals",
        "Ask Key could not save an access record. Credential operations continue, and this warning will remain until recording succeeds.",
        "Ask Key could not prepare Agent access. Open the app to review the vault state.",
        "Ask Key could not apply this decision. Open Pending requests to retry or reject it.",
        "Ask Key could not clean up expired recycled credentials.",
        "Ask Key could not remove a temporary credential file. It will keep retrying.",
        "Ask Key could not schedule expiry reminders because notifications are turned off.",
        "Ask Key could not deliver an expiry reminder. The reminder will be retried.",
        "Ask Key has a credential expiring soon",
        "Open Ask Key to review the expiry date.",
        "Open Ask Key",
        "Quit Ask Key",
        "Default Timed Allow",
        "15 minutes",
        "30 minutes",
        "60 minutes",
        "2 hours",
        "Off",
        "Add a credential to keep it in Ask Key.",
        "Launch at Login",
        "Credential Library",
        "All credentials",
        "Ungrouped",
        "Recycle Bin",
        "Agent approvals",
        "Pending requests",
        "Access records",
        "Agent access",
        "Settings",
    ]

    static func profile(for language: String) -> LanguageProfile {
        if let exact = profiles.first(where: { $0.id == language || $0.catalogCode == language }) {
            return exact
        }
        if let matched = profiles.first(where: { $0.matchesSystem(language) }) {
            return matched
        }
        return profiles.first(where: { $0.id == "en" })
            ?? LanguageProfile(
                id: "en",
                catalogCode: "en",
                formatLocaleIdentifier: "en",
                titleKey: "English",
                published: true,
                systemPrefixes: ["en"],
                oneIsSingular: true
            )
    }

    static func resolve(mode: String, systemLanguages: [String]? = nil) -> String {
        if let exact = profiles.first(where: { $0.id == mode }) {
            return exact.id
        }
        if mode == "system" {
            let first = (systemLanguages ?? Self.systemLanguages()).first ?? "en"
            return profile(for: first).id
        }
        return profile(for: mode).id
    }

    @MainActor
    static func apply(mode: String) {
        let resolved = resolve(mode: mode)
        current = resolved
        store.adopt(mode: mode, resolved: resolved)
    }

    static func titleKey(for mode: String) -> String {
        if mode == "system" {
            return "Follow System"
        }
        return profile(for: mode).titleKey
    }

    static func catalogLanguage(from language: String) -> String {
        profile(for: language).catalogCode
    }

    static func brandName(language: String) -> String {
        localized("Ask Key", language: language)
    }

    static func locale(for language: String) -> Locale {
        Locale(identifier: profile(for: language).formatLocaleIdentifier)
    }

    static func pluralCategory(count: Int, language: String) -> String {
        profile(for: language).pluralCategory(count: count)
    }

    static func localized(_ key: String, language: String) -> String {
        let code = catalogLanguage(from: language)
        if let value = table(language: code)[key] {
            return value
        }
        if code != "en", let value = table(language: "en")[key] {
            return value
        }
        return key
    }

    static func localizedCount(
        _ otherKey: String,
        oneKey: String,
        count: Int,
        language: String
    ) -> String {
        let code = catalogLanguage(from: language)
        let form = pluralCategory(count: count, language: code)
        cacheLock.lock()
        let variant = pluralTables[code]?[otherKey]?[form] ?? pluralTables[code]?[otherKey]?["other"]
        cacheLock.unlock()
        let key = variant == nil && form == "one" ? oneKey : otherKey
        let format = variant ?? localized(key, language: code)
        return String(format: format, locale: locale(for: code), arguments: [count])
    }

    static func containsKey(_ key: String, language: String = "en") -> Bool {
        table(language: language)[key] != nil
    }

    static func ownsCatalogTable(_ table: [String: String]) -> Bool {
        ownershipSentinels.allSatisfy { table[$0] != nil } && table.count >= 100
    }

    static func catalogProvenance(language: String) -> CatalogProvenance {
        _ = table(language: language)
        let code = catalogLanguage(from: language)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return provenanceByLanguage[code]
            ?? CatalogProvenance(language: code, source: .empty, keyCount: 0, bundleURL: nil)
    }

    static func table(language: String) -> [String: String] {
        let code = catalogLanguage(from: language)
        cacheLock.lock()
        if let cached = tables[code] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let loaded = loadOwnedCatalog(language: code)
        cacheLock.lock()
        tables[code] = loaded.table
        pluralTables[code] = loaded.plurals
        provenanceByLanguage[code] = loaded.provenance
        cacheLock.unlock()
        return loaded.table
    }

    private static let cacheLock = NSLock()
    private static var tables: [String: [String: String]] = [:]
    private static var pluralTables: [String: [String: [String: String]]] = [:]
    private static var provenanceByLanguage: [String: CatalogProvenance] = [:]

    private static func ownedBundles() -> [Bundle] {
        var seen: Set<URL> = []
        var bundles: [Bundle] = []
        #if SWIFT_PACKAGE
        if seen.insert(Bundle.module.bundleURL).inserted {
            bundles.append(Bundle.module)
        }
        #endif
        if seen.insert(Bundle.main.bundleURL).inserted {
            bundles.append(Bundle.main)
        }
        return bundles
    }

    private static func tableDirectories(for language: String) -> [String] {
        let canonical = Locale(identifier: language).identifier
        return Array(Set(["\(language).lproj", "\(canonical).lproj"]))
    }

    private static func loadOwnedCatalog(language: String) -> (
        table: [String: String],
        plurals: [String: [String: String]],
        provenance: CatalogProvenance
    ) {
        for bundle in ownedBundles() {
            for directory in tableDirectories(for: language) {
                if let url = bundle.url(
                    forResource: "Localizable",
                    withExtension: "strings",
                    subdirectory: directory
                ), var table = NSDictionary(contentsOf: url) as? [String: String] {
                    var plurals: [String: [String: String]] = [:]
                    if let dictURL = bundle.url(
                        forResource: "Localizable",
                        withExtension: "stringsdict",
                        subdirectory: directory
                    ) {
                        mergeStringsdict(dictURL, into: &table, plurals: &plurals)
                    }
                    if ownsCatalogTable(table) {
                        return (
                            table,
                            plurals,
                            CatalogProvenance(
                                language: language,
                                source: .compiledStrings,
                                keyCount: table.count,
                                bundleURL: bundle.bundleURL
                            )
                        )
                    }
                }
            }
            if let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
               let parsed = parseStringCatalog(url, language: language),
               ownsCatalogTable(parsed.table) {
                return (
                    parsed.table,
                    parsed.plurals,
                    CatalogProvenance(
                        language: language,
                        source: .stringCatalog,
                        keyCount: parsed.table.count,
                        bundleURL: bundle.bundleURL
                    )
                )
            }
        }
        return (
            [:],
            [:],
            CatalogProvenance(language: language, source: .empty, keyCount: 0, bundleURL: nil)
        )
    }

    private static func mergeStringsdict(
        _ url: URL,
        into table: inout [String: String],
        plurals: inout [String: [String: String]]
    ) {
        guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else {
            return
        }
        for (key, raw) in dictionary {
            guard let entry = raw as? [String: Any] else { continue }
            var forms: [String: String] = [:]
            for (nestedKey, nestedRaw) in entry {
                guard nestedKey != "NSStringLocalizedFormatKey",
                      let nested = nestedRaw as? [String: Any],
                      nested["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" else {
                    continue
                }
                for (form, value) in nested {
                    guard !form.hasPrefix("NSString"), let text = value as? String else { continue }
                    forms[form] = text
                }
            }
            guard !forms.isEmpty else { continue }
            plurals[key] = forms
            if table[key] == nil {
                table[key] = forms["other"] ?? forms["one"]
            }
        }
    }

    private static func parseStringCatalog(
        _ url: URL,
        language: String
    ) -> (table: [String: String], plurals: [String: [String: String]])? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            return nil
        }
        var table: [String: String] = [:]
        var plurals: [String: [String: String]] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  let localization = localizations[language] as? [String: Any] else {
                continue
            }
            if let unit = localization["stringUnit"] as? [String: Any],
               let value = unit["value"] as? String {
                table[key] = value
            }
            if let variations = localization["variations"] as? [String: Any],
               let plural = variations["plural"] as? [String: Any] {
                var forms: [String: String] = [:]
                for (form, formRaw) in plural {
                    guard let formEntry = formRaw as? [String: Any],
                          let unit = formEntry["stringUnit"] as? [String: Any],
                          let value = unit["value"] as? String else {
                        continue
                    }
                    forms[form] = value
                }
                if !forms.isEmpty {
                    plurals[key] = forms
                    if table[key] == nil {
                        table[key] = forms["other"] ?? forms["one"]
                    }
                }
            }
        }
        return (table, plurals)
    }
}
