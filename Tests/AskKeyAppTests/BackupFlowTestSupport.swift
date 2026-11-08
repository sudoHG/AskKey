import CryptoKit
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

/// The prompts the view model showed, and what the next one answers.
final class BackupPromptLog {
    var reasons: [String] = []
    var result: ManagementAuthenticationResult = .authenticated(.allow)
}

/// The panels and the disk behind a backup flow: fixed panel answers and an
/// in-memory file system that records every write.
final class BackupDiskRecorder {
    var exportDestination: URL?
    var importFile: URL?
    var savePanelNames: [String] = []
    var openPanelCount = 0
    var writes: [URL] = []
    var files: [URL: Data] = [:]
    var write: (Data, URL) throws -> Void

    init() {
        write = { _, _ in }
        write = { [unowned self] data, url in self.files[url] = data }
    }
}

/// Two real libraries in temporary directories with different App keys, and
/// a view model whose system authentication, panels and disk are recorded.
@MainActor
final class BackupFlowFixture {
    let source: Vault
    let target: Vault
    let prompts = BackupPromptLog()
    let disk = BackupDiskRecorder()
    let viewModel: VaultViewModel
    private let directory: URL
    private let suiteName: String

    init(language: String = "en") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = Vault(store: try VaultStore(path: directory.appendingPathComponent("source.db").path),
                       key: SymmetricKey(size: .bits256))
        target = Vault(store: try VaultStore(path: directory.appendingPathComponent("target.db").path),
                       key: SymmetricKey(size: .bits256))
        suiteName = "BackupFlow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(language, forKey: "languageMode")
        let prompts = prompts
        let target = target
        viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            unlockVault: {},
            beginManagementSession: { try target.beginManagementSession(using: $0) },
            beginOnboardingManagementSession: { try target.beginOnboardingCreation() },
            authenticateDeviceOwner: { presentation in
                prompts.reasons.append(presentation.reasonKey)
                return prompts.result
            },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            agentAccessPolicyOperations: AgentAccessPolicyTestState().operations,
            credentialMutations: CredentialWorkspaceMutations.readOnly { ([], [], [], false) }
                .counting { try target.storedCredentialCount() }
        )
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    var operations: BackupOperations {
        let source = source
        let target = target
        let disk = disk
        return BackupOperations(
            export: { try source.exportBackup(using: $0) },
            plan: { try target.planBackupImport($0, recoveryKey: $1, renameSuffix: $2) },
            commit: { try target.commitBackupImport($0, using: $1) },
            chooseExportDestination: { name in
                disk.savePanelNames.append(name)
                return disk.exportDestination
            },
            chooseImportFile: {
                disk.openPanelCount += 1
                return disk.importFile
            },
            write: { data, url in
                disk.writes.append(url)
                try disk.write(data, url)
            },
            read: { url in
                guard let data = disk.files[url] else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
        )
    }

    /// The App side of an unlocked management window, and the Vault's session.
    func openManagement(in vault: Vault) throws {
        try vault.beginManagementSession(using: .allow)
        viewModel.isLocked = false
        viewModel.hasManagementSession = true
    }

    func text(_ name: String, _ value: String, in vault: Vault) throws {
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createTextCredential(.init(name: name, value: value, environmentVariable: "TOKEN"), using: .allow)
    }

    /// Exports the source library and places the file where the open panel finds it.
    func sourceBackup(named name: String = "Ask Key Backup 2026-11-08.askkeybackup") throws -> (url: URL, recoveryKey: String) {
        try source.beginManagementSession(using: .allow)
        let export = try source.exportBackup(using: .allow)
        let url = directory.appendingPathComponent(name)
        disk.files[url] = export.fileBytes
        disk.importFile = url
        return (url, export.recoveryKey.groupedText)
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

class BackupFlowTestCase: AskKeyAppTestCase {
    private var previousLanguage = AppLanguage.current
    private var fixtures: [BackupFlowFixture] = []

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguage.current
    }

    override func tearDown() {
        fixtures.forEach { $0.tearDown() }
        fixtures = []
        AppLanguage.current = previousLanguage
        super.tearDown()
    }

    func makeFixture(language: String = "en") throws -> BackupFlowFixture {
        let fixture = try BackupFlowFixture(language: language)
        fixtures.append(fixture)
        return fixture
    }
}
