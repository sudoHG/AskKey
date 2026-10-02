import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

@MainActor
final class LocalVaultLifecycleViewModelTests: XCTestCase {
    func testAppErasePassesTheSelectedEnglishLanguageToCore() async {
        let recorder = AppEraseRecorder()
        let defaults = UserDefaults(suiteName: "EnglishErase-\(UUID().uuidString)") ?? .standard
        defaults.set("en", forKey: "languageMode")
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            eraseLocalLibrary: { confirmation, language, authenticator in
                try recorder.erase(
                    confirmation: confirmation,
                    language: language,
                    authenticator: authenticator
                )
            },
            authenticateLocalErase: { reason in recorder.authenticate(reason: reason) },
            preferences: AppPreferences(defaults: defaults)
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let completed = await viewModel.eraseLocalLibrary(confirmation: "ERASE")

        XCTAssertTrue(completed)
        XCTAssertEqual(recorder.eraseAttempts, 1)
    }

    func testAppEraseUsesFreshAuthenticationAndLocksAfterCoreCompletes() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "ChineseErase-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("zh-Hans", forKey: "languageMode")
        let preferences = AppPreferences(defaults: defaults)
        let recorder = AppEraseRecorder()
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            eraseLocalLibrary: { confirmation, language, authenticator in
                try recorder.erase(
                    confirmation: confirmation,
                    language: language,
                    authenticator: authenticator
                )
            },
            authenticateLocalErase: { reason in recorder.authenticate(reason: reason) },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let completed = await viewModel.eraseLocalLibrary(
            confirmation: LocalVaultEraseLanguage.simplifiedChinese.confirmationText
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(recorder.authenticationAttempts, 1)
        XCTAssertEqual(recorder.eraseAttempts, 1)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testSettingsKeepLocalEraseAndCloudDeletionSeparateAndHonest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/CredentialManagementView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Erase Local Data"))
        XCTAssertTrue(source.contains("FrozenEraseConfirmationPresentation.accepts(eraseWord)"))
        XCTAssertTrue(source.contains("confirmation: eraseWord"))
    }

}

private final class AppEraseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var authenticationAttempts = 0
    private(set) var eraseAttempts = 0

    func authenticate(reason: String) -> ManagementAuthenticator {
        lock.lock(); defer { lock.unlock() }
        authenticationAttempts += 1
        XCTAssertEqual(reason, "Erase the local Ask Key vault")
        return .allow
    }

    func erase(
        confirmation: String,
        language: LocalVaultEraseLanguage,
        authenticator: ManagementAuthenticator
    ) throws {
        lock.lock(); defer { lock.unlock() }
        eraseAttempts += 1
        XCTAssertEqual(language.confirmationText, confirmation)
        XCTAssertTrue(authenticator.confirm(reason: "test"))
    }
}
