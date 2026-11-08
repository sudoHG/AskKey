import AppKit
import Darwin
import UniformTypeIdentifiers
import AskKeyVault

/// The Vault calls, panels and file access behind the backup flows (ADR 0012).
/// Tests replace them with a temporary library, fixed panel choices and a
/// recording disk.
struct BackupOperations {
    var export: (ManagementAuthenticator) throws -> BackupExport
    var plan: (_ fileBytes: Data, _ recoveryKey: String, _ renameSuffix: (Int) -> String) throws -> BackupImportPlan
    var commit: (BackupImportPlan, ManagementAuthenticator) throws -> BackupImportResult
    /// Asks where to save a new backup; nil when the person cancels.
    var chooseExportDestination: @MainActor (_ defaultName: String) -> URL?
    /// Asks for a backup file to import; nil when the person cancels.
    var chooseImportFile: @MainActor () -> URL?
    var write: (Data, URL) throws -> Void
    var read: (URL) throws -> Data

    static var live: BackupOperations {
        BackupOperations(
            export: { try Vault.shared.exportBackup(using: $0) },
            plan: { try Vault.shared.planBackupImport($0, recoveryKey: $1, renameSuffix: $2) },
            commit: { try Vault.shared.commitBackupImport($0, using: $1) },
            chooseExportDestination: BackupPanels.chooseExportDestination,
            chooseImportFile: BackupPanels.chooseImportFile,
            write: BackupFileStorage.write,
            read: { try Data(contentsOf: $0) }
        )
    }
}

enum BackupPanels {
    static let fileExtension = "askkeybackup"
    static var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data }

    @MainActor
    static func chooseExportDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.identifier = NSUserInterfaceItemIdentifier("backup-export-panel")
        panel.message = appLocalized("Keep the backup file and its recovery key in different places.")
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.identifier = NSUserInterfaceItemIdentifier("backup-import-panel")
        panel.message = appLocalized("Choose an Ask Key backup file.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [contentType]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum BackupFileStorage {
    /// Writes the sealed backup next to its destination with owner-only
    /// permissions, then renames it into place, so the destination either
    /// gets the whole file or is left as it was. A failed write leaves no
    /// partial file behind.
    static func write(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).\(BackupPanels.fileExtension)-partial")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var moved = false
        defer { if !moved { unlink(temporary.path) } }
        do {
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
            guard fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else { throw posixError() }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
        moved = true
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

extension VaultViewModel {
    /// The default file name: a date and nothing from the library.
    static func backupFileName(on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return appLocalizedFormat("Ask Key Backup %@", formatter.string(from: date)) + "." + BackupPanels.fileExtension
    }

    /// The text the Vault appends to a conflicting name, in the App's language:
    /// "(from backup)", then "(from backup 2)" and so on.
    static func backupRenameSuffix(language: String) -> (Int) -> String {
        { number in
            number == 1
                ? AppLanguage.localized("(from backup)", language: language)
                : String(format: AppLanguage.localized("(from backup %lld)", language: language),
                         locale: AppLanguage.locale(for: language), arguments: [number])
        }
    }

    /// What a refused backup file or recovery key means for the person: a
    /// typo, a key that does not open the file (or a damaged file), a file
    /// from a newer Ask Key, or contents Ask Key refuses. Nil for other errors.
    static func backupFileMessage(for error: Error) -> String? {
        switch error {
        case is BackupRecoveryKeyError:
            return appLocalized("This recovery key has a typo. Check each group of four characters and try again.")
        case BackupFileError.cannotOpen:
            return appLocalized("This recovery key doesn't open this file, or the file is damaged.")
        case BackupFileError.newerFormatVersion:
            return appLocalized("This backup was made by a newer version of Ask Key. Update Ask Key, then try again.")
        case BackupFileError.invalidContents:
            return appLocalized("This backup contains a credential Ask Key can't import, so nothing was imported.")
        default:
            return nil
        }
    }

    /// Opens the import flow from the first-run screen: an existing
    /// management session, or the first-run allowance of an empty library.
    func beginBackupRestore() -> Bool {
        hasManagementSession || beginOnboardingManagement()
    }

    /// Keeps the management session and the unlocked state alive while a
    /// backup flow waits for the person.
    func renewBackupActivity() {
        renewSession()
        renewManagementSession()
    }

    /// Fresh system authentication for one backup step. Nil when cancelled or
    /// failed, or when management ended while the prompt was open.
    func authenticateBackupStep(_ action: ManagementAuthenticationAction) async -> ManagementAuthenticator? {
        renewBackupActivity()
        let generation = managementAuthorizationGeneration
        guard let authenticator = await confirmDeviceOwner(reason: action.reasonKey),
              generation == managementAuthorizationGeneration, !isLocked, !Task.isCancelled else { return nil }
        return authenticator
    }
}
