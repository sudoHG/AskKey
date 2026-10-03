import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class AppLanguageExperienceTests: AppLanguageExperienceTestSupport {
    func testFollowSystemSimplifiedChineseAndEnglishResolveInstantly() {
        XCTAssertEqual(AppLanguage.resolve(mode: "en", systemLanguages: ["zh-Hans-CN"]), "en")
        XCTAssertEqual(AppLanguage.resolve(mode: "zh-Hans", systemLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.brandName(language: "en"), "Ask Key")
        XCTAssertEqual(AppLanguage.brandName(language: "zh-Hans"), "请旨")
        XCTAssertEqual(AppLanguage.technicalName, "AskKey")
        XCTAssertEqual(AppLanguage.technicalCommand, "askkey")

        AppLanguage.current = "en"
        XCTAssertEqual(appLocalized("Ask Key"), "Ask Key")
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(appLocalized("Ask Key"), "请旨")
        XCTAssertEqual(appLocalized("Ask Key"), "请旨", "switching must not require a process restart")
    }

    func testLanguageModeSurvivesRelaunchAndCanRollBack() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.languageMode, "system")
        XCTAssertFalse(preferences.hasCompletedOnboarding)

        let login = LoginItemProbe()
        let first = makeViewModel(preferences: preferences, login: login)
        first.languageMode = "zh-Hans"
        XCTAssertEqual(first.brandName, "请旨")
        XCTAssertEqual(appLocalized("Ask Key"), "请旨")

        let relaunched = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login
        )
        XCTAssertEqual(relaunched.languageMode, "zh-Hans")
        XCTAssertEqual(relaunched.brandName, "请旨")

        relaunched.languageMode = "en"
        XCTAssertEqual(AppPreferences(defaults: defaults).languageMode, "en")
        XCTAssertEqual(relaunched.brandName, "Ask Key")
        XCTAssertEqual(appLocalized("Ask Key"), "Ask Key")
    }
}
