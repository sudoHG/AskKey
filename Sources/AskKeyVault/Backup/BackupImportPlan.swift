import Foundation

public enum BackupImportError: Error, Equatable, Sendable {
    /// The library changed since the plan was made, or a recycled credential
    /// the plan would add reached the end of its Recycle Bin retention. Nothing
    /// was written; make and review a new plan.
    case libraryChanged
    /// The caller's rename suffix does not form a valid credential name, or
    /// does not give a different name for each number.
    case invalidRenameSuffix
}

/// A backup credential the import adds.
public struct BackupImportAddition: Equatable, Sendable {
    /// The credential's name in the backup.
    public let backupName: String
    /// Its name in this library after the import.
    public let name: String
    /// A recycled backup credential is added to the Recycle Bin.
    public let isRecycled: Bool

    public var isRenamed: Bool { name != backupName }
}

/// A backup credential skipped because a credential with identical content
/// already has its name or one of its rename candidates.
public struct BackupImportMatch: Equatable, Sendable {
    /// The credential's name in the backup.
    public let backupName: String
    /// The credential with identical content: one in this library, or one
    /// this import adds.
    public let name: String
}

/// What an import would do to the library as it was when the plan was made
/// (ADR 0012). Commit applies exactly this plan, or nothing if the library
/// has changed since. The plan holds the backup's values in memory; printing,
/// interpolating or dumping it shows only the summary.
public struct BackupImportPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let backupCreatedAt: Date
    /// Every credential the import adds with its final name, renamed ones included.
    public let additions: [BackupImportAddition]
    /// Active backup credentials whose identical copy is already in the
    /// library outside the Recycle Bin, or is added by this import.
    public let skippedIdentical: [BackupImportMatch]
    /// Active backup credentials whose identical copy is in this library's
    /// Recycle Bin; restore it there instead.
    public let skippedInRecycleBin: [BackupImportMatch]
    /// Recycled backup credentials whose name is already taken or whose
    /// 30-day Recycle Bin retention has ended, by their backup names.
    public let skippedRecycled: [String]
    /// Groups the import creates: the backup's empty groups and those an
    /// added credential carries. A group whose backup members are all skipped
    /// is not created.
    public let createdGroups: [String]

    let credentials: [BackupImportPlannedCredential]
    /// Names the stored group list gains: the created groups no imported
    /// credential carries.
    let storedGroups: [String]
    /// Binds the plan to the library state and App key it was computed against.
    let libraryDigest: Data

    init(backupCreatedAt: Date, outcome: BackupImportPlanner.Outcome, libraryDigest: Data) {
        self.backupCreatedAt = backupCreatedAt
        additions = outcome.credentials.map {
            .init(backupName: $0.source.name, name: $0.name, isRecycled: $0.source.deletedAt != nil)
        }
        skippedIdentical = outcome.skippedIdentical
        skippedInRecycleBin = outcome.skippedInRecycleBin
        skippedRecycled = outcome.skippedRecycled
        createdGroups = outcome.createdGroups
        credentials = outcome.credentials
        storedGroups = outcome.storedGroups
        self.libraryDigest = libraryDigest
    }

    public var renamed: [BackupImportAddition] { additions.filter(\.isRenamed) }

    public var description: String {
        "BackupImportPlan(additions: \(additions.count), renamed: \(renamed.count), "
            + "skipped: \(skippedIdentical.count + skippedInRecycleBin.count + skippedRecycled.count), "
            + "createdGroups: \(createdGroups.count))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "backupCreatedAt": backupCreatedAt, "additions": additions, "skippedIdentical": skippedIdentical,
            "skippedInRecycleBin": skippedInRecycleBin, "skippedRecycled": skippedRecycled,
            "createdGroups": createdGroups,
        ], displayStyle: .struct)
    }
}

/// What a committed import added.
public struct BackupImportResult: Equatable, Sendable {
    /// Every added credential with its final name, renamed ones included.
    public let additions: [BackupImportAddition]
    /// Groups the import created, including empty ones.
    public let createdGroups: [String]

    public var renamed: [BackupImportAddition] { additions.filter(\.isRenamed) }
}

/// A backup credential with the name and group spelling it gets in this library.
struct BackupImportPlannedCredential {
    let source: BackupSnapshot.Credential
    let name: String
    let groupName: String?
}
