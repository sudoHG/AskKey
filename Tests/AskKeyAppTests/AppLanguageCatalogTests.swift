import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class AppLanguageCatalogTests: AppLanguageExperienceTestSupport {
    func testPopoverQuitEntryUsesStandardTerminationAndLocalizedCopy() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Views/VaultPopover.swift"),
            encoding: .utf8
        )
        let quitEntry = #"Divider\(\)\.padding\(\.horizontal, 10\)\s*"#
            + #"menuEntry\(appLocalized\("Quit Ask Key"\), systemImage: "power"\) \{\s*"#
            + #"closePopover\(\)\s*NSApp\.terminate\(nil\)\s*\}\s*"#
            + #"\.accessibilityIdentifier\("menubar-quit"\)"#
        XCTAssertNotNil(source.range(of: quitEntry, options: .regularExpression))
        XCTAssertEqual(AppLanguage.localized("Quit Ask Key", language: "en"), "Quit Ask Key")
        XCTAssertEqual(AppLanguage.localized("Quit Ask Key", language: "zh-Hans"), "退出请旨")
    }

    func testManagementAuthenticationCopyMatchesTheSelectedLanguage() {
        XCTAssertEqual(
            AppLanguage.localized(CredentialManagementCopy.manageReason, language: "en"),
            "Confirm credential management"
        )
        XCTAssertEqual(
            AppLanguage.localized(CredentialManagementCopy.manageReason, language: "zh-Hans"),
            "请确认以管理凭证"
        )
        XCTAssertEqual(
            AppLanguage.localized(
                VaultError.managementAuthenticationRequired.localizedDescription,
                language: "zh-Hans"
            ),
            "需要确认后才能继续管理凭证。"
        )
        XCTAssertEqual(
            AppLanguage.localized("System authentication failed.", language: "zh-Hans"),
            "系统验证失败。"
        )
        let chineseReasons = [
            CredentialManagementCopy.revealReason: "确认查看凭证值",
            CredentialManagementCopy.pauseReason: "确认暂停 Agent 访问",
            CredentialManagementCopy.resumeReason: "确认恢复 Agent 访问",
            "Clear Ask Key access records": "确认清除请旨访问记录",
            "Erase the local Ask Key vault": "确认抹除请旨本机凭证库",
            "View the frozen file submitted for approval": "确认查看待批准的冻结文件内容",
            "Disable system authentication for read approvals": "关闭批准读取的系统验证",
        ]
        for (reason, expected) in chineseReasons {
            XCTAssertEqual(AppLanguage.localized(reason, language: "zh-Hans"), expected)
        }

        let approvalReasons: [(String, String)] = [
            (
                ManagementAuthenticationAction.approveRead.reasonKey,
                "授权 AI 助手使用所选凭证"
            ),
            (
                ManagementAuthenticationAction.approveWrite.reasonKey,
                "授权 AI 助手修改所选凭证"
            ),
        ]
        for (reasonKey, chineseReason) in approvalReasons {
            XCTAssertEqual(
                AppLanguage.table(language: "zh-Hans")[reasonKey],
                chineseReason
            )
            XCTAssertEqual(
                ManagementAuthenticationPresentation(
                    reasonKey: reasonKey,
                    language: "zh-Hans"
                ).reason,
                chineseReason
            )
            XCTAssertEqual(
                ManagementAuthenticationPresentation(
                    reasonKey: reasonKey,
                    language: "en"
                ).reason,
                reasonKey
            )
        }
    }

    func testBundleDisplayNameMatchesBrandInBothLanguages() throws {
        let resources = repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Resources")
        let english = NSDictionary(
            contentsOf: resources.appendingPathComponent("en.lproj/InfoPlist.strings")
        ) as? [String: String]
        let chinese = NSDictionary(
            contentsOf: resources.appendingPathComponent("zh-Hans.lproj/InfoPlist.strings")
        ) as? [String: String]

        XCTAssertEqual(english?["CFBundleDisplayName"], "Ask Key")
        XCTAssertEqual(english?["CFBundleName"], "Ask Key")
        XCTAssertEqual(chinese?["CFBundleDisplayName"], "请旨")
        XCTAssertEqual(chinese?["CFBundleName"], "请旨")
    }

    func testCatalogCoversBrandOnboardingLoginWarningNotificationsAndMenus() {
        for key in AppLanguage.requiredKeys {
            let english = AppLanguage.localized(key, language: "en")
            let chinese = AppLanguage.localized(key, language: "zh-Hans")
            XCTAssertFalse(english.isEmpty, "missing English value for \(key)")
            XCTAssertFalse(chinese.isEmpty, "missing Chinese value for \(key)")
            let keepEnglish = Set(["Codex", "Cursor", "Grok CLI", "English"])
            if !keepEnglish.contains(key) {
                XCTAssertNotEqual(chinese, key, "Chinese catalog still falls back to the English key \(key)")
            }
        }
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "en"), "Ask Key")
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "zh-Hans"), "请旨")
        XCTAssertFalse(AppLanguage.localized("Ask Key", language: "en").contains("AskKey"))
        XCTAssertFalse(AppLanguage.localized("Ask Key", language: "zh-Hans").contains("AskKey"))
        XCTAssertFalse(AppLanguage.localized("Quit Ask Key", language: "zh-Hans").contains("AskKey"))
        XCTAssertTrue(
            AppLanguage.localized(
                "CLI and MCP cannot obtain credentials while Ask Key is not running.",
                language: "zh-Hans"
            ).contains("请旨未运行")
        )
    }

    func testKeyUIDoesNotHardcodeTechnicalBrandOrSkipRequiredCopy() throws {
        let root = repoRoot()
        let files = [
            "Sources/AskKeyAppKit/AskKeyApp.swift",
            "Sources/AskKeyAppKit/Views/CredentialManagementView.swift",
            "Sources/AskKeyAppKit/Views/VaultPopover.swift",
            "Sources/AskKeyAppKit/Views/SettingsView.swift",
            "Sources/AskKeyAppKit/Views/FirstRunOnboardingView.swift",
        ]
        for relative in files {
            let source = try CredentialManagementSource.read(from: root, relative: relative)
            XCTAssertFalse(source.contains("Text(\"AskKey\")"), "\(relative) still uses technical AskKey as brand")
            XCTAssertFalse(source.contains("Window(\"AskKey\""), "\(relative) still titles the window AskKey")
            XCTAssertFalse(source.contains("Welcome to AskKey"), "\(relative) still greets with AskKey")
            XCTAssertFalse(source.contains("Quit AskKey"), "\(relative) still quits AskKey")
            XCTAssertFalse(source.contains("keep it in AskKey"), "\(relative) still mixes the technical name into UI copy")
        }

        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/Views/FirstRunOnboardingView.swift"),
            encoding: .utf8
        )
        for needle in [
            "WorkspaceVisualContract.welcomeCopy",
            "Save access keys, login details, certificates, or a combination of them.",
            "Import a regular file or .env; the original file is not modified.",
            "One credential can contain multiple items",
            "Decide Agent requests immediately",
            "Ask Key runs in the background",
            "Launch at Login",
            "Create First Credential",
            "Start Using",
        ] {
            XCTAssertTrue(onboarding.contains(needle), "onboarding is missing \(needle)")
        }

        let settings = try CredentialManagementSource.read(
            from: root,
            relative: "Sources/AskKeyAppKit/Views/CredentialManagementView.swift"
        )
        XCTAssertTrue(settings.contains("Language"))
        XCTAssertTrue(settings.contains("zh-Hans"))
        XCTAssertTrue(settings.contains("Launch at Login"))
        XCTAssertTrue(settings.contains("Timed Allow"))
        let language = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/AppLanguage.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(language.contains("Follow System"))
        XCTAssertTrue(language.contains("publishedModes"))

        let manager = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manager.contains("onboardingRoute = .fileImport"))
        XCTAssertTrue(manager.contains("FrozenTemplateChooserPage"))
    }

    func testOnboardingCopyHasNoSecretsAndTechnicalIdentifiersStayUntranslated() {
        let chinese = AppLanguage.table(language: "zh-Hans")
        for (key, value) in chinese {
            XCTAssertFalse(value.contains("sk-"), "catalog leaked a secret-like token in \(key)")
            XCTAssertFalse(value.contains("AKIA"), "catalog leaked a secret-like token in \(key)")
            XCTAssertFalse(value.contains("-----BEGIN"), "catalog leaked a private key in \(key)")
        }
        XCTAssertEqual(AppLanguage.technicalName, "AskKey")
        XCTAssertEqual(AppLanguage.technicalCommand, "askkey")
        XCTAssertEqual(chinese["Codex"], "Codex")
        XCTAssertEqual(chinese["Cursor"], "Cursor")
        XCTAssertEqual(chinese["Grok CLI"], "Grok CLI")
    }
}
