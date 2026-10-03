import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyBroker
@testable import AskKeyVault

/// Independent RED for the 331-393 / 331-394 incremental findings.
/// These assert runtime behavior, not “source contains @Observable”.
@MainActor
final class LocalizationRemediationTests: AskKeyAppTestCase {
    override func setUp() {
        super.setUp()
        AppLanguage.systemLanguages = { ["en-US"] }
        AppLanguage.apply(mode: "en")
    }

    override func tearDown() {
        AppLanguage.systemLanguages = { Locale.preferredLanguages }
        AppLanguage.apply(mode: "en")
        super.tearDown()
    }

    func testOwnedCatalogIsNotASystemFrameworkTable() {
        let english = AppLanguage.table(language: "en")
        XCTAssertGreaterThanOrEqual(english.count, 640, "SwiftPM must load the Ask Key catalog, not a 228-key system table")
        XCTAssertEqual(english["Ask Key"], "Ask Key")
        XCTAssertEqual(english["Credential Library"], "Credential Library")
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "en"), "Ask Key")
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "zh-Hans"), "请旨")
        XCTAssertTrue(AppLanguage.ownsCatalogTable(english))
        XCTAssertFalse(
            AppLanguage.catalogProvenance(language: "en").bundleURL?.path.contains("MobileDevice.framework") == true,
            "owned table must not come from MobileDevice.framework"
        )

        var foreign: [String: String] = [:]
        for index in 0..<228 {
            foreign["k\(index)"] = "v\(index)"
        }
        XCTAssertFalse(AppLanguage.ownsCatalogTable(foreign), "a non-empty foreign table must be rejected")
    }

    func testDisplayedApprovalPromptRedrawsWhenLanguageChanges() throws {
        AppLanguage.apply(mode: "en")
        let request = BrokerApprovalOperationRequest(
            operationID: "remediation",
            credentialID: "prod",
            targetID: "prod",
            operation: .read,
            payloadDigest: "redacted",
            credentialName: "生产环境 API",
            callerName: "Codex",
            callerPurpose: "发布新版本"
        )
        let prompt = FrozenAgentApprovalPrompt(
            request: request,
            expiresAt: Date().addingTimeInterval(299),
            timedAllowanceEnabled: true,
            finish: { _ in }
        )
        _ = NSApplication.shared
        let size = CGSize(width: 360, height: 430)
        let hosting = NSHostingView(rootView: prompt.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let before = try pngData(from: hosting)
        AppLanguage.apply(mode: "zh-Hans")
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let after = try pngData(from: hosting)
        XCTAssertNotEqual(
            before,
            after,
            "an already-displayed approval window must redraw when the live language changes"
        )
        XCTAssertEqual(appLocalized("Deny"), "拒绝")
    }



    func testThirdLanguageComesFromOneDeclarationAndFullCatalog() throws {
        XCTAssertFalse(AppLanguage.publishedModes.contains("qps-ploc"))
        XCTAssertEqual(AppLanguage.resolve(mode: "qps-ploc"), "qps-ploc")
        XCTAssertEqual(AppLanguage.catalogLanguage(from: "qps-ploc"), "qps-ploc")
        XCTAssertEqual(
            Set(AppLanguage.publishedModes),
            Set(AppLanguage.profiles.filter(\.published).map(\.id) + ["system"])
        )

        let english = AppLanguage.table(language: "en")
        let qps = AppLanguage.table(language: "qps-ploc")
        XCTAssertEqual(qps.count, english.count, "pseudo-locale must cover the whole catalog, not 3 chrome keys")
        XCTAssertEqual(qps["Settings"], "[!!Settings!!]")
        XCTAssertEqual(qps["Credential Library"], "[!!Credential Library!!]")
        XCTAssertTrue(qps["Pause Agent Access"]?.hasPrefix("[!!") == true)

        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/AppLanguage.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("case \"qps-ploc\""), "locale branches must not hard-code extra languages")
        let script = try String(
            contentsOf: repoRoot().appendingPathComponent("scripts/sync-string-catalog.py"),
            encoding: .utf8
        )
        XCTAssertFalse(script.contains("write_strings(\"en\""), "sync script must walk catalog locales")
    }

    func testDynamicCoreErrorsMapThroughCatchToAlert() throws {
        let defaults = UserDefaults(suiteName: "331-392-error-\(UUID().uuidString)")!
        defaults.set("zh-Hans", forKey: "languageMode")
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in })
        )
        model.languageMode = "zh-Hans"

        let interpolated = VaultError.credentialNameConflict("示例").localizedDescription
        XCTAssertTrue(interpolated.contains("示例"))
        XCTAssertEqual(interpolated, "A credential named '示例' already exists.")

        do {
            throw VaultError.credentialNameConflict("示例")
        } catch {
            model.presentError(error)
        }

        let conflict = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(conflict.contains("示例"))
        XCTAssertFalse(conflict.contains("already exists"))
        XCTAssertEqual(conflict, "已存在名为“示例”的凭证。")
        XCTAssertEqual(displayedUserMessage(conflict), conflict)

        do {
            throw VaultError.credentialNotFound("发布")
        } catch {
            model.presentError(error)
        }
        let missing = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(missing.contains("发布"))
        XCTAssertFalse(missing.contains("was not found"))

        do {
            throw VaultError.databaseError("SELECT * FROM secrets WHERE token=sk-live")
        } catch {
            model.presentError(error)
        }
        let generic = try XCTUnwrap(model.errorMessage)
        XCTAssertFalse(generic.contains("sk-live"))
        XCTAssertFalse(generic.contains("SELECT"))

        let host = NSHostingView(
            rootView: Text(displayedUserMessage(model.errorMessage ?? ""))
                .frame(width: 320, height: 40)
        )
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 40)
        host.layoutSubtreeIfNeeded()
        host.display()
        XCTAssertEqual(displayedUserMessage(model.errorMessage ?? ""), generic)
    }

    func testMenuPauseUsesActionKeyNotAuthenticationReason() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Views/VaultPopover.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("Pause Agent Access"))
        XCTAssertTrue(source.contains("Resume Agent Access"))
        XCTAssertFalse(source.contains("Pause Agent access"))
        XCTAssertFalse(source.contains("Resume Agent access"))
        XCTAssertEqual(appLocalized("Pause Agent Access"), "Pause Agent Access")
        AppLanguage.apply(mode: "zh-Hans")
        XCTAssertEqual(appLocalized("Pause Agent Access"), "暂停 Agent 访问")
        XCTAssertEqual(appLocalized("Pause Agent access"), "确认暂停 Agent 访问")
    }

    func testLockedCopyPluralUsesCatalogNotALanguageBranch() {
        let englishOne = WorkspaceVisualContract.lockedCopy(language: "en", credentialCount: 1)
        XCTAssertTrue(englishOne.message.contains("credential is protected"))
        let englishMany = WorkspaceVisualContract.lockedCopy(language: "en", credentialCount: 2)
        XCTAssertTrue(englishMany.message.contains("credentials are protected"))
        let chineseOne = WorkspaceVisualContract.lockedCopy(language: "zh-Hans", credentialCount: 1)
        XCTAssertTrue(chineseOne.message.contains("凭证"))
        XCTAssertFalse(chineseOne.message.contains("credential is protected"))
        let source = try? String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/WorkspaceVisualContract.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source?.contains("language != \"zh-Hans\" && credentialCount == 1") == true,
            "plural selection must not hard-code Chinese vs English"
        )
    }

    func testBackgroundApplyKeepsLockAndUpdatesStore() async {
        await applyFromBackground("zh-Hans")
        XCTAssertEqual(AppLanguage.current, "zh-Hans")
        assertLanguageReadersAgree("zh-Hans")
    }

    func testOlderBackgroundApplyCannotOverwriteNewerMainSelection() async {
        AppLanguage.apply(mode: "zh-Hans")
        await applyFromBackground("en")
        AppLanguage.apply(mode: "zh-Hans")
        XCTAssertEqual(AppLanguage.current, "zh-Hans")
        XCTAssertEqual(AppLanguage.store.resolved, "zh-Hans")
        await drainMainQueue()
        assertLanguageReadersAgree("zh-Hans")
    }

    func testNewerBackgroundApplyIsNotLostToEarlierMainSelection() async {
        AppLanguage.apply(mode: "en")
        await applyFromBackground("zh-Hans")
        await drainMainQueue()
        assertLanguageReadersAgree("zh-Hans")
    }

    func testMultipleBackgroundAppliesCommitInCallOrder() async {
        await applyFromBackground("en")
        await applyFromBackground("zh-Hans")
        await applyFromBackground("en")
        await drainMainQueue()
        assertLanguageReadersAgree("en")
    }

    func testApplyReturnCommitsBothReadersBeforeReturning() async {
        AppLanguage.apply(mode: "zh-Hans")
        assertLanguageReadersAgree("zh-Hans")
        await drainMainQueue()
        assertLanguageReadersAgree("zh-Hans")
    }

    private func applyFromBackground(_ mode: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Task { @MainActor in
                    AppLanguage.apply(mode: mode)
                    continuation.resume()
                }
            }
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func assertLanguageReadersAgree(_ expected: String) {
        XCTAssertEqual(AppLanguage.current, expected)
        XCTAssertEqual(AppLanguage.store.resolved, expected)
        XCTAssertEqual(AppLanguage.store.mode, expected)
        XCTAssertEqual(appLocalized("Settings"), expected == "zh-Hans" ? "设置" : "Settings")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func pngData(from hosting: NSView) throws -> Data {
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "LocalizationRemediationTests", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "LocalizationRemediationTests", code: 2)
        }
        return data
    }
}
