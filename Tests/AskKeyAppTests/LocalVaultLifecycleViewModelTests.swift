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
        XCTAssertTrue(source.contains("Leave unchecked to keep the cloud backup"))
        XCTAssertTrue(source.contains("deletingICloudWith"))
        XCTAssertFalse(source.contains("deleteICloudBackup(\n                                            recoveryKey"))
    }

    func testAppExposesInspectFullReplacementTakeoverAndSeparateCloudDelete() async throws {
        let recorder = ICloudAppRecorder()
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            inspectICloudBackup: { try recorder.inspect(recoveryKey: $0) },
            listICloudBackupConflicts: { _ in ["opaque-conflict-path"] },
            restoreICloudBackup: {
                try recorder.restore(recoveryKey: $0, generationID: $1, authenticator: $2)
            },
            takeOwnershipOfICloudBackup: {
                try recorder.takeOwnership(recoveryKey: $0, generationID: $1, authenticator: $2)
            },
            deleteICloudBackup: { try recorder.delete(recoveryKey: $0, authenticator: $1) },
            listICloudBackupNamespaces: { ["old-namespace", "new-namespace"] },
            iCloudBackupEnabled: { true },
            createICloudBackupNamespace: { try recorder.createNamespace(authenticator: $0) },
            activateICloudBackupNamespace: {
                try recorder.activateNamespace(recoveryKey: $0, authenticator: $1)
            },
            authenticateICloudLifecycle: { recorder.authenticate(reason: $0) },
            preferences: AppPreferences(defaults: UserDefaults(suiteName: "ICloudLifecycle-\(UUID())")!),
            isAgentAccessPaused: { false },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let preview = try XCTUnwrap(
            viewModel.inspectICloudBackup(recoveryKey: "recovery-key").first
        )
        let restoredResult = await viewModel.restoreICloudBackup(
            recoveryKey: "recovery-key",
            generationID: preview.id
        )
        let restored = try XCTUnwrap(restoredResult)
        let tookOwnership = await viewModel.takeOwnershipOfICloudBackup(
            recoveryKey: "recovery-key",
            generationID: restored.id
        )
        let deletedCloud = await viewModel.deleteICloudBackup(recoveryKey: "recovery-key")
        let newRecoveryKey = await viewModel.createICloudBackupNamespace()
        let firstGeneration = await viewModel.activateICloudBackupNamespace(
            recoveryKey: try XCTUnwrap(newRecoveryKey)
        )

        XCTAssertTrue(tookOwnership)
        XCTAssertTrue(deletedCloud)
        XCTAssertEqual(newRecoveryKey, "new-recovery-key")
        XCTAssertEqual(firstGeneration, restored)
        XCTAssertEqual(preview, restored)
        XCTAssertEqual(
            viewModel.listICloudBackupNamespaces(),
            ["old-namespace", "new-namespace"]
        )
        XCTAssertEqual(
            viewModel.listICloudBackupConflicts(recoveryKey: "recovery-key"),
            ["opaque-conflict-path"]
        )
        XCTAssertEqual(
            recorder.actions,
            [
                "inspect", "restore", "takeover", "delete-cloud",
                "create-namespace", "activate-namespace",
            ]
        )
        XCTAssertEqual(recorder.authenticationReasons.count, 5)
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

private final class ICloudAppRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []
    private var recordedReasons: [String] = []
    private let generation = ICloudBackupGeneration(
        id: "11111111-1111-4111-8111-111111111111",
        createdAt: Date(timeIntervalSince1970: 2_000_000_000)
    )

    var actions: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedActions
    }

    var authenticationReasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedReasons
    }

    func inspect(recoveryKey: String) throws -> [ICloudBackupGeneration] {
        try record("inspect", recoveryKey: recoveryKey)
        return [generation]
    }

    func restore(
        recoveryKey: String,
        generationID: String,
        authenticator: ManagementAuthenticator
    ) throws -> ICloudBackupGeneration {
        try requireAuthentication(authenticator)
        XCTAssertEqual(generationID, generation.id)
        try record("restore", recoveryKey: recoveryKey)
        return generation
    }

    func takeOwnership(
        recoveryKey: String,
        generationID: String,
        authenticator: ManagementAuthenticator
    ) throws {
        try requireAuthentication(authenticator)
        XCTAssertEqual(generationID, generation.id)
        try record("takeover", recoveryKey: recoveryKey)
    }

    func delete(recoveryKey: String, authenticator: ManagementAuthenticator) throws {
        try requireAuthentication(authenticator)
        try record("delete-cloud", recoveryKey: recoveryKey)
    }

    func createNamespace(authenticator: ManagementAuthenticator) throws -> String {
        try requireAuthentication(authenticator)
        lock.lock(); recordedActions.append("create-namespace"); lock.unlock()
        return "new-recovery-key"
    }

    func activateNamespace(
        recoveryKey: String,
        authenticator: ManagementAuthenticator
    ) throws -> ICloudBackupGeneration {
        try requireAuthentication(authenticator)
        XCTAssertEqual(recoveryKey, "new-recovery-key")
        lock.lock(); recordedActions.append("activate-namespace"); lock.unlock()
        return generation
    }

    func authenticate(reason: String) -> ManagementAuthenticator {
        lock.lock(); recordedReasons.append(reason); lock.unlock()
        return .allow
    }

    private func record(_ action: String, recoveryKey: String) throws {
        XCTAssertEqual(recoveryKey, "recovery-key")
        lock.lock(); recordedActions.append(action); lock.unlock()
    }

    private func requireAuthentication(_ authenticator: ManagementAuthenticator) throws {
        guard authenticator.confirm(reason: "test") else {
            throw ICloudBackupError.authenticationRequired
        }
    }
}
