import Foundation
import XCTest
@testable import AskKeyAppKit

/// The language list AppKit and Sparkle use for a launch (#266).
@MainActor
final class LaunchLanguageOverrideTests: AskKeyAppTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AskKey.launch-language.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        AppLanguage.systemLanguages = { ["zh-Hans-CN", "en-US"] }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppLanguage.systemLanguages = { AppLanguage.macOSPreferredLanguages() }
        AppLanguage.apply(mode: "en")
        super.tearDown()
    }

    func testAnExplicitChoiceGoesFirstAndFollowSystemKeepsTheMacOSOrder() {
        let macOS = ["zh-Hans-CN", "en-US"]
        XCTAssertEqual(
            LaunchLanguageOverride.preferredLanguages(mode: "en", macOSLanguages: macOS),
            ["en", "zh-Hans-CN", "en-US"]
        )
        XCTAssertEqual(
            LaunchLanguageOverride.preferredLanguages(mode: "zh-Hans", macOSLanguages: ["en-US"]),
            ["zh-Hans", "en-US"]
        )
        XCTAssertEqual(
            LaunchLanguageOverride.preferredLanguages(mode: "zh-Hans", macOSLanguages: ["zh-Hans", "en"]),
            ["zh-Hans", "en"]
        )
        XCTAssertEqual(LaunchLanguageOverride.preferredLanguages(mode: "en", macOSLanguages: []), ["en"])
        for mode in ["system", "qps-ploc", "fr", ""] {
            XCTAssertNil(
                LaunchLanguageOverride.preferredLanguages(mode: mode, macOSLanguages: macOS),
                "\(mode) must leave the macOS order unchanged"
            )
        }
    }

    func testFollowSystemReadsTheMacOSListAfterAnExplicitChoiceIsSavedAndReverted() {
        let preferences = AppPreferences(defaults: defaults)
        let domain = FakeArgumentDomain(values: ["NSDocumentRevisionsDebugMode": "YES"])

        preferences.languageMode = "en"
        AppLanguage.applySavedPreferenceAtLaunch(preferences: preferences, argumentDomain: domain.domain)
        XCTAssertEqual(domain.languages, ["en", "zh-Hans-CN", "en-US"])
        XCTAssertEqual(AppLanguage.store.resolved, "en")

        preferences.languageMode = "system"
        AppLanguage.applySavedPreferenceAtLaunch(preferences: preferences, argumentDomain: domain.domain)
        XCTAssertNil(domain.languages, "reverting to Follow System must remove the override")
        XCTAssertEqual(domain.values["NSDocumentRevisionsDebugMode"] as? String, "YES")
        XCTAssertEqual(AppLanguage.store.resolved, "zh-Hans", "Follow System resolves from the macOS list")

        XCTAssertEqual(
            defaults.persistentDomain(forName: suiteName)?.keys.sorted(), ["languageMode"],
            "the override never reaches the app's defaults on disk"
        )
    }

    func testFollowSystemWithoutAnOverrideLeavesTheArgumentDomainAlone() {
        let domain = FakeArgumentDomain(values: [:])
        LaunchLanguageOverride.apply(mode: "system", macOSLanguages: ["en-US"], to: domain.domain)
        XCTAssertEqual(domain.writes, 0)
    }

    func testALanguageLaunchArgumentWins() {
        let domain = FakeArgumentDomain(values: [LaunchLanguageOverride.key: ["en"]], commandLineSetsLanguages: true)
        LaunchLanguageOverride.apply(mode: "zh-Hans", macOSLanguages: ["zh-Hans-CN"], to: domain.domain)
        LaunchLanguageOverride.apply(mode: "system", macOSLanguages: ["zh-Hans-CN"], to: domain.domain)
        XCTAssertEqual(domain.languages, ["en"])
        XCTAssertEqual(domain.writes, 0)
        XCTAssertTrue(
            ManagementAuthenticationSubprocess.arguments(language: "en", describeOnly: false)
                .contains("-" + LaunchLanguageOverride.key),
            "the Touch ID helper process keeps the language its parent passes"
        )
    }

    func testMacOSLanguagesPreferAPerAppChoiceThenTheSystemList() {
        let app = kCFPreferencesCurrentApplication as String
        let system = kCFPreferencesAnyApplication as String
        func read(_ values: [String: [String]]) -> [String] {
            AppLanguage.macOSPreferredLanguages { values[$0 as String] as CFPropertyList? }
        }
        XCTAssertEqual(read([app: ["en-GB"], system: ["zh-Hans-CN"]]), ["en-GB"])
        XCTAssertEqual(read([app: [], system: ["zh-Hans-CN"]]), ["zh-Hans-CN"])
        XCTAssertEqual(read([system: ["zh-Hans-CN", "en-US"]]), ["zh-Hans-CN", "en-US"])
        XCTAssertEqual(read([:]), [])
    }

    /// The pitfall in #266: `Locale.preferredLanguages` reflects the override.
    /// The real reader must not. The process's argument domain is restored.
    func testMacOSLanguagesIgnoreTheOverrideInThisProcess() {
        // Fix this process's bundle languages first, so the temporary
        // override below cannot become them.
        _ = Bundle.main.preferredLocalizations
        let process = LaunchLanguageOverride.ArgumentDomain.process
        let saved = process.read()
        defer { process.write(saved) }
        let before = AppLanguage.macOSPreferredLanguages()

        var values = saved
        values[LaunchLanguageOverride.key] = ["fo"]
        process.write(values)

        XCTAssertEqual(Locale.preferredLanguages.first, "fo", "the override is live in this process")
        XCTAssertEqual(AppLanguage.macOSPreferredLanguages(), before)
        XCTAssertFalse(AppLanguage.macOSPreferredLanguages().contains("fo"))
    }
}

private final class FakeArgumentDomain {
    var values: [String: Any]
    private(set) var writes = 0
    private let commandLineSetsLanguages: Bool

    init(values: [String: Any], commandLineSetsLanguages: Bool = false) {
        self.values = values
        self.commandLineSetsLanguages = commandLineSetsLanguages
    }

    var languages: [String]? { values[LaunchLanguageOverride.key] as? [String] }

    var domain: LaunchLanguageOverride.ArgumentDomain {
        LaunchLanguageOverride.ArgumentDomain(
            commandLineSetsLanguages: commandLineSetsLanguages,
            read: { self.values },
            write: {
                self.values = $0
                self.writes += 1
            }
        )
    }
}
