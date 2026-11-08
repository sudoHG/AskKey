import Foundation
import AskKeyVault

/// Import Backup (ADR 0012): open panel → recovery key → preview → confirm →
/// fresh system authentication → result. Nothing is written before the
/// authenticated commit, and a plan the library has outgrown is replaced by a
/// new preview instead of being committed.
@Observable
@MainActor
final class BackupImportFlow: Identifiable {
    enum Stage: Equatable {
        case enteringKey
        case preview
        case result
    }

    private(set) var stage = Stage.enteringKey
    private(set) var fileName = ""
    var recoveryKey = ""
    /// Why the file or the typed key was refused, shown under the key field.
    private(set) var keyMessage: String?
    private(set) var plan: BackupImportPlan?
    /// The library changed after the previous preview, so this preview is new.
    private(set) var planWasRefreshed = false
    private(set) var result: BackupImportResult?
    private(set) var errorMessage: String?
    private(set) var isWorking = false

    @ObservationIgnored private var fileBytes: Data?
    @ObservationIgnored private let vault: VaultViewModel
    @ObservationIgnored private let operations: BackupOperations
    @ObservationIgnored private let language: String

    init(vault: VaultViewModel, operations: BackupOperations = .live) {
        self.vault = vault
        self.operations = operations
        language = AppLanguage.current
    }

    /// True when the backup adds nothing to this library.
    var hasNothingToImport: Bool {
        guard let plan else { return true }
        return plan.additions.isEmpty && plan.createdGroups.isEmpty
    }

    /// Shows the open panel and reads the chosen file. False when the person
    /// cancels or the file cannot be read.
    func chooseFile() -> Bool {
        vault.renewBackupActivity()
        guard let url = operations.chooseImportFile() else { return false }
        do {
            fileBytes = try operations.read(url)
        } catch {
            vault.errorMessage = appLocalized("The backup file could not be read.")
            return false
        }
        fileName = url.lastPathComponent
        stage = .enteringKey
        return true
    }

    /// Opens the file with the typed recovery key and computes the preview
    /// against the current library. Nothing is written.
    @discardableResult
    func openBackup() -> Bool {
        guard stage == .enteringKey, let fileBytes, !isWorking else { return false }
        vault.renewBackupActivity()
        keyMessage = nil
        errorMessage = nil
        do {
            plan = try operations.plan(fileBytes, recoveryKey, VaultViewModel.backupRenameSuffix(language: language))
            planWasRefreshed = false
            stage = .preview
            return true
        } catch {
            if let message = VaultViewModel.backupFileMessage(for: error) {
                keyMessage = message
            } else {
                errorMessage = UserFacingCopy.message(for: error)
            }
            return false
        }
    }

    /// Returns from the preview to the recovery key.
    func editRecoveryKey() {
        guard stage == .preview, !isWorking else { return }
        plan = nil
        planWasRefreshed = false
        errorMessage = nil
        stage = .enteringKey
    }

    /// Authenticates and writes the previewed plan. If the library changed
    /// since the preview, nothing is written and a new preview replaces it.
    @discardableResult
    func confirm() async -> Bool {
        guard stage == .preview, let plan, !hasNothingToImport, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        guard let authenticator = await vault.authenticateBackupStep(.importBackup) else {
            // A failed prompt is reported here; the window's alert would wait behind this sheet.
            errorMessage = vault.errorMessage
            vault.errorMessage = nil
            return false
        }
        do {
            result = try operations.commit(plan, authenticator)
        } catch BackupImportError.libraryChanged {
            refreshPlan()
            return false
        } catch {
            errorMessage = UserFacingCopy.message(for: error)
            return false
        }
        stage = .result
        discardSecrets()
        return true
    }

    /// Ends the flow without writing anything.
    func cancel() {
        discardSecrets()
        result = nil
    }

    /// Ends the flow after the result; the library lists the imported credentials.
    func finish() {
        discardSecrets()
        result = nil
        vault.refreshCredentialSummary()
    }

    private func refreshPlan() {
        guard let fileBytes else { return }
        do {
            plan = try operations.plan(fileBytes, recoveryKey, VaultViewModel.backupRenameSuffix(language: language))
            planWasRefreshed = true
        } catch {
            plan = nil
            planWasRefreshed = false
            stage = .enteringKey
            errorMessage = VaultViewModel.backupFileMessage(for: error) ?? UserFacingCopy.message(for: error)
        }
    }

    private func discardSecrets() {
        fileBytes = nil
        recoveryKey = ""
        plan = nil
    }
}
