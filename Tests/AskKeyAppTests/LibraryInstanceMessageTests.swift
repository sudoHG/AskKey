import Foundation
import XCTest
@testable import AskKeyAppKit

@MainActor
final class LibraryInstanceMessageTests: AppLanguageExperienceTestSupport {
    func testEarlyAlertsUseSavedLanguageOrSystemLanguageWithoutStartingRuntime() throws {
        let initialized = AppRuntimeState.normalRuntimeInitialized
        let previousMode = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousMode) }
        let preferences = AppPreferences(defaults: defaults)
        let key = try XCTUnwrap(LibraryInstanceActivationResult.differentLocation.messageKey)
        AppLanguage.systemLanguages = { ["zh-Hans-CN"] }
        AppLanguage.applySavedPreference(preferences: preferences)
        XCTAssertTrue(appLocalized(key).contains("\u{53e6}\u{4e00}\u{4e2a}\u{4f4d}\u{7f6e}\u{7684}\u{8bf7}\u{65e8}"))
        XCTAssertEqual(AppLanguage.store.resolved, "zh-Hans")

        preferences.languageMode = "en"
        AppLanguage.applySavedPreference(preferences: preferences)
        XCTAssertEqual(appLocalized(key), key)
        XCTAssertEqual(AppLanguage.store.mode, "en")

        AppLanguage.systemLanguages = { ["en-US"] }
        preferences.languageMode = "zh-Hans"
        AppLanguage.applySavedPreference(preferences: preferences)
        XCTAssertTrue(appLocalized(key).contains("\u{53e6}\u{4e00}\u{4e2a}\u{4f4d}\u{7f6e}\u{7684}\u{8bf7}\u{65e8}"))
        XCTAssertEqual(AppRuntimeState.normalRuntimeInitialized, initialized)
    }

    func testStartupAppliesLanguageBeforeAcquiringLibraryInstance() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/App/AskKeyApp.swift"),
            encoding: .utf8
        )
        let language = try XCTUnwrap(source.range(of: "AppLanguage.applySavedPreference()"))
        let instance = try XCTUnwrap(source.range(of: "AppRuntimeState.acquireLibraryInstance()"))
        let main = try XCTUnwrap(source.range(of: "Self.main()"))
        XCTAssertLessThan(language.lowerBound, instance.lowerBound)
        XCTAssertLessThan(instance.lowerBound, main.lowerBound)
    }

    func testDifferentLocationReplyExplainsQuitAndApplicationsWithoutWeakeningIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = directory.appendingPathComponent("installed/AskKey")
        let other = directory.appendingPathComponent("disk-image/AskKey")
        let identity = LibraryInstanceApplicationIdentity(bundleIdentifier: "example.AskKey", executableURL: executable)
        let result = LibraryInstanceActivationResult.classify(
            identity: identity, bundleIdentifier: "example.AskKey", executableURL: other, pid: 123, ownPID: 456
        )
        XCTAssertFalse(identity.matches(bundleIdentifier: "example.AskKey", executableURL: other, pid: 123, ownPID: 456))
        XCTAssertEqual(result, .differentLocation)
        let key = try XCTUnwrap(result.messageKey)
        XCTAssertTrue(key.contains("different location"))
        XCTAssertTrue(key.contains("Quit it"))
        XCTAssertTrue(key.contains("Applications"))
        XCTAssertFalse(key.contains("did not respond"))
        XCTAssertTrue(AppLanguage.containsKey(key, language: "en"))
        XCTAssertTrue(AppLanguage.containsKey(key, language: "zh-Hans"))
        let chinese = AppLanguage.localized(key, language: "zh-Hans")
        XCTAssertTrue(chinese.contains("\u{8bf7}\u{65e8}"))
        XCTAssertTrue(chinese.contains("\u{5148}\u{9000}\u{51fa}"))
        XCTAssertTrue(chinese.contains("\u{5e94}\u{7528}\u{7a0b}\u{5e8f}"))
        XCTAssertEqual(LibraryInstanceActivationResult.classify(
            identity: identity, bundleIdentifier: "example.AskKey", executableURL: executable, pid: 123, ownPID: 456
        ), .activated)
        XCTAssertNil(LibraryInstanceActivationResult.activated.messageKey)
    }

    func testUnverifiedRepliesNeverUseTheNoReplyMessage() throws {
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-AskKey")
        let identity = LibraryInstanceApplicationIdentity(bundleIdentifier: "example.AskKey", executableURL: executable)
        for (bundle, path, pid) in [
            ("example.Other", Optional(executable), Int32(123)),
            ("example.AskKey", nil, Int32(123)),
            ("example.AskKey", Optional(executable), Int32(456)),
            ("example.AskKey", Optional(executable), Int32(0)),
        ] {
            let result = LibraryInstanceActivationResult.classify(
                identity: identity, bundleIdentifier: bundle, executableURL: path, pid: pid, ownPID: 456
            )
            XCTAssertEqual(result, .unverifiedReply)
            let key = try XCTUnwrap(result.messageKey)
            XCTAssertFalse(key.contains("did not respond"))
            XCTAssertTrue(AppLanguage.containsKey(key, language: "zh-Hans"))
        }
        XCTAssertTrue(try XCTUnwrap(LibraryInstanceActivationResult.noReply.messageKey).contains("did not respond"))
    }
}
