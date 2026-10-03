import Foundation
import XCTest
@testable import AskKeyAppKit

/// RED/GREEN contract for 331-392: one String Catalog, one lookup, no mixed chrome.
@MainActor
final class LocalizationUnificationTests: AskKeyAppTestCase {
    private let chromeKeys = [
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

    func testReportedMixedLanguagePatternCannotOccur() throws {
        let appLanguage = try source("Sources/AskKeyAppKit/AppLanguage.swift")
        let settingsPage = try source("Sources/AskKeyAppKit/Views/CredentialManagementView.swift")
        let support = try source("Sources/AskKeyAppKit/Views/SettingsSupport.swift")

        let sidebarOnlyInFileTable = chromeKeys.contains { key in
            !appLanguage.contains("\"\(key)\"") || appLanguage.range(of: "chineseBuiltin") != nil
                && !builtinContains(appLanguage, key: key)
        }
        let settingsUsesInlineBilingual = settingsPage.contains("frozenLocalized(\"设置\", \"Settings\")")
        let parallelLookupStillExists = support.contains("func frozenLocalized")
            || appLanguage.contains("chineseBuiltin")
            || appLanguage.contains("#filePath")

        XCTAssertFalse(
            (sidebarOnlyInFileTable && settingsUsesInlineBilingual) || parallelLookupStillExists,
            """
            Reported symptom: sidebar English keys + settings body Chinese.
            That pattern is possible while chrome keys live only in a file table \
            (and not in the builtin fallback) while settings titles use frozenLocalized.
            """
        )
    }

    func testStringCatalogIsTheOnlyHumanTranslationSource() throws {
        let catalog = repoRoot()
            .appendingPathComponent("Sources/AskKeyAppKit/Resources/Localizable.xcstrings")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: catalog.path),
            "Localizable.xcstrings must be the only human-maintained translation source"
        )
        let stringsFiles = try FileManager.default.contentsOfDirectory(
            at: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Resources"),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                return (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )) ?? []
            }
            return [url]
        }.filter { $0.lastPathComponent == "Localizable.strings" }

        XCTAssertTrue(
            stringsFiles.isEmpty,
            "committed Localizable.strings next to the catalog collide with Xcode xcstrings compilation"
        )
        for file in stringsFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(
                text.contains("generated from Localizable.xcstrings"),
                "\(file.lastPathComponent) must not be a second human-maintained table"
            )
        }
    }

    func testProductionHasNoParallelTranslationMechanisms() throws {
        let files = try productionSwiftFiles()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                text.contains("func frozenLocalized"),
                "\(file.lastPathComponent) still defines inline bilingual lookup"
            )
            XCTAssertFalse(
                text.contains("chineseBuiltin"),
                "\(file.lastPathComponent) still has a builtin translation table"
            )
            XCTAssertFalse(
                text.contains("englishBuiltin"),
                "\(file.lastPathComponent) still has a builtin translation table"
            )
            if file.lastPathComponent == "AppLanguage.swift" {
                XCTAssertFalse(
                    text.contains("#filePath"),
                    "translation lookup must not fall back to the developer source tree"
                )
            }
            let inlineCalls = text.components(separatedBy: "frozenLocalized(").count - 1
            XCTAssertEqual(
                inlineCalls,
                0,
                "\(file.lastPathComponent) still calls frozenLocalized \(inlineCalls) time(s)"
            )
            XCTAssertFalse(
                text.contains("chinese: String, english: String"),
                "\(file.lastPathComponent) still keeps a parallel bilingual copy pair"
            )
        }
    }

    func testWorkspaceChromeAndSettingsBodyShareOneCatalogLanguage() {
        AppLanguage.current = "zh-Hans"
        let settingsTitle = appLocalized("Settings")
        XCTAssertEqual(settingsTitle, "设置")
        for key in chromeKeys {
            let value = appLocalized(key)
            XCTAssertNotEqual(value, key, "chrome key \(key) fell back to English")
            XCTAssertFalse(
                looksEnglish(value) && looksChinese(settingsTitle),
                "chrome '\(key)' is English while settings title is Chinese"
            )
        }

        AppLanguage.current = "en"
        XCTAssertEqual(appLocalized("Settings"), "Settings")
        XCTAssertEqual(appLocalized("Credential Library"), "Credential Library")
    }

    func testLanguageChangeIsObservableWithoutRestart() throws {
        XCTAssertEqual(Set(AppLanguage.publishedModes), ["system", "zh-Hans", "en"])
        AppLanguage.apply(mode: "zh-Hans")
        XCTAssertEqual(AppLanguage.store.mode, "zh-Hans")
        XCTAssertEqual(AppLanguage.store.resolved, "zh-Hans")
        XCTAssertEqual(appLocalized("Settings"), "设置")
        AppLanguage.apply(mode: "en")
        XCTAssertEqual(AppLanguage.store.resolved, "en")
        XCTAssertEqual(appLocalized("Settings"), "Settings")
        AppLanguage.apply(mode: "zh-Hans")
        XCTAssertEqual(AppLanguage.store.resolved, "zh-Hans")
        XCTAssertEqual(appLocalized("Settings"), "设置", "switching must not require a process restart")
    }

    func testThirdLanguageExtensionNeedsOnlyCatalogAndLanguageList() throws {
        XCTAssertFalse(AppLanguage.publishedModes.contains("qps-ploc"))
        XCTAssertEqual(AppLanguage.resolve(mode: "qps-ploc"), "qps-ploc")
        let english = AppLanguage.table(language: "en")
        let qps = AppLanguage.table(language: "qps-ploc")
        XCTAssertEqual(qps.count, english.count)
        XCTAssertEqual(
            AppLanguage.localized("Settings", language: "qps-ploc"),
            "[!!Settings!!]"
        )
        let settings = try source("Sources/AskKeyAppKit/Views/CredentialManagementView.swift")
        XCTAssertFalse(
            settings.contains("qps-ploc"),
            "test-only locale must not be hard-coded into Settings"
        )
    }

    func testCatalogCoversProductionKeysAndFormatPlaceholders() throws {
        let catalog = try loadCatalog()
        let keys = try productionLocalizationKeys()
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            guard let entry = catalog[key] else {
                XCTFail("catalog missing production key: \(key)")
                continue
            }
            let english = entry["en"]
            XCTAssertNotNil(english, "missing English value for \(key)")
            if let english, english != key {
                let allowedAliases = ["AskKey": "Ask Key", "Brand monogram": "A"]
                XCTAssertEqual(english, allowedAliases[key], "English value must match the key or a declared alias: \(key)")
            }
            XCTAssertNotNil(entry["zh-Hans"], "missing Chinese translation for \(key)")
            let englishPlaceholders = placeholderTokens(key)
            if let chinese = entry["zh-Hans"] {
                XCTAssertEqual(
                    placeholderTokens(chinese),
                    englishPlaceholders,
                    "placeholder mismatch for \(key)"
                )
            }
        }
    }

    func testLookupDoesNotDependOnSourceTreePath() throws {
        let source = try self.source("Sources/AskKeyAppKit/AppLanguage.swift")
        XCTAssertFalse(source.contains("#filePath"))
        XCTAssertFalse(source.contains("Resources/\\(language).lproj/Localizable.strings"))
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(appLocalized("Credential Library"), "凭证库")
        XCTAssertEqual(appLocalized("Settings"), "设置")
    }

    private func looksEnglish(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.isASCII }
            && !looksChinese(value)
    }

    private func looksChinese(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    private func builtinContains(_ appLanguage: String, key: String) -> Bool {
        guard let range = appLanguage.range(of: "chineseBuiltin") else { return false }
        return appLanguage[range.upperBound...].contains("\"\(key)\"")
    }

    private func placeholderTokens(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[#0\\- +']*(?:\\d+)?(?:\\.\\d+)?[hlqLjzt]*[@%dDuUxXoOfeEgGcCsS]")
        let ns = value as NSString
        return pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        }.sorted()
    }

    private func loadCatalog() throws -> [String: [String: String]] {
        let url = repoRoot()
            .appendingPathComponent("Sources/AskKeyAppKit/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any] ?? [:]
        var result: [String: [String: String]] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            var values: [String: String] = [:]
            for (locale, localization) in localizations {
                guard let localization = localization as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String else { continue }
                values[locale] = value
            }
            result[key] = values
        }
        return result
    }

    private func productionLocalizationKeys() throws -> Set<String> {
        var keys = Set<String>()
        let pattern = try NSRegularExpression(
            pattern: #"appLocalized(?:Format)?\(\s*"((?:\\.|[^"\\])*)""#
        )
        for file in try productionSwiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "\\\"", with: "\""))
            }
        }
        return keys
    }

    private func productionSwiftFiles() throws -> [URL] {
        let root = repoRoot().appendingPathComponent("Sources/AskKeyAppKit")
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" {
                files.append(url)
            }
        }
        return files
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
