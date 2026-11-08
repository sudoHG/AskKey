import Foundation
import AskKeyVault

/// Export Backup (ADR 0012): fresh system authentication → the recovery key,
/// shown once → the person re-enters its last group → save panel → an atomic
/// owner-only write. Nothing is written before the last step, and cancelling
/// at any step discards the sealed backup and its key.
@Observable
@MainActor
final class BackupExportFlow: Identifiable {
    private(set) var recoveryKey: String?
    var confirmation = ""
    /// The file name after a successful save.
    private(set) var savedFileName: String?
    private(set) var errorMessage: String?
    private(set) var isAuthenticating = false

    @ObservationIgnored private var fileBytes: Data?
    @ObservationIgnored private let vault: VaultViewModel
    @ObservationIgnored private let operations: BackupOperations
    @ObservationIgnored private let now: () -> Date

    init(vault: VaultViewModel, operations: BackupOperations = .live, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.operations = operations
        self.now = now
    }

    /// The recovery key's groups of four, for display.
    var recoveryKeyGroups: [String] {
        recoveryKey?.split(separator: "-").map(String.init) ?? []
    }

    /// True once the typed text matches the key's last group, read the way a
    /// recovery key is read: case, spaces and hyphens are ignored, and I and L
    /// read as 1 and O as 0.
    var isConfirmed: Bool {
        guard let last = recoveryKeyGroups.last else { return false }
        return Self.symbols(confirmation) == last
    }

    /// Authenticates and seals the whole library under a new recovery key.
    /// Returns false when authentication or the export did not succeed; the
    /// Vault requires an active management session.
    @discardableResult
    func start() async -> Bool {
        guard !isAuthenticating, recoveryKey == nil else { return false }
        guard vault.hasManagementSession, !vault.isLocked else {
            vault.presentError(VaultError.managementAuthenticationRequired)
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        guard let authenticator = await vault.authenticateBackupStep(.exportBackup) else { return false }
        do {
            let export = try operations.export(authenticator)
            fileBytes = export.fileBytes
            recoveryKey = export.recoveryKey.groupedText
            return true
        } catch {
            vault.presentError(error)
            return false
        }
    }

    func copyRecoveryKey() {
        guard let recoveryKey else { return }
        noteActivity()
        vault.clipboard.copy(recoveryKey, clearAfter: vault.clipboardClearSeconds)
    }

    /// Typing and reading keep management open while the key is on screen.
    func noteActivity() {
        vault.renewBackupActivity()
    }

    /// Asks where to save and writes the file. Returns true once the file is
    /// saved. A cancelled panel keeps the recovery key on screen.
    @discardableResult
    func save() -> Bool {
        guard isConfirmed, let fileBytes else { return false }
        vault.renewBackupActivity()
        errorMessage = nil
        guard let destination = operations.chooseExportDestination(VaultViewModel.backupFileName(on: now())) else {
            return false
        }
        do {
            try operations.write(fileBytes, destination)
        } catch {
            errorMessage = appLocalized("The backup could not be saved there, and no file was written. Choose another location and try again.")
            return false
        }
        savedFileName = destination.lastPathComponent
        discardSecrets()
        return true
    }

    /// Discards the sealed backup and its recovery key without writing anything.
    func cancel() {
        discardSecrets()
    }

    private func discardSecrets() {
        fileBytes = nil
        recoveryKey = nil
        confirmation = ""
    }

    private static func symbols(_ text: String) -> String {
        String(text.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ", "\t", "\n": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        })
    }
}
