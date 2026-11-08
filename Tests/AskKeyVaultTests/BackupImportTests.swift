import Foundation
import XCTest
@testable import AskKeyVault

/// Merge import through `Vault`, between libraries with different App keys.
final class BackupImportTests: BackupImportTestCase {
    private static let longName = "Long " + String(repeating: "x", count: 245)

    // MARK: - Empty library

    func testRoundTripIntoAnEmptyLibraryKeepsEveryFieldWithNewIDs() throws {
        let sourceClock = BackupTestClock(SyntheticBackupLibrary.createdAt)
        let source = try makeLibrary(now: { sourceClock.now })
        try SyntheticBackupLibrary.populate(source.vault, clock: sourceClock)
        let export = try source.vault.exportBackup(using: .allow)
        let importedAt = SyntheticBackupLibrary.createdAt.addingTimeInterval(24 * 60 * 60)
        let targetClock = BackupTestClock(importedAt)
        let target = try makeLibrary(now: { targetClock.now })
        XCTAssertNotEqual(try source.key.withUnsafeBytes { Data($0) }, try target.key.withUnsafeBytes { Data($0) })

        // An empty library plans and commits without a management session.
        let plan = try plan(export, into: target.vault)
        XCTAssertEqual(plan.backupCreatedAt, SyntheticBackupLibrary.recycledAt)
        XCTAssertEqual(plan.additions.count, SyntheticBackupLibrary.credentialCount + SyntheticBackupLibrary.recycledCount)
        XCTAssertEqual(plan.additions.filter(\.isRecycled).map(\.name), ["Synthetic Recycled Token"])
        XCTAssertEqual(plan.renamed, [])
        XCTAssertEqual(plan.skippedIdentical, [])
        XCTAssertEqual(plan.skippedInRecycleBin, [])
        XCTAssertEqual(plan.skippedRecycled, [])
        XCTAssertEqual(plan.createdGroups, ["Synthetic Archive", "Synthetic Empty Group", "Synthetic Ops"])
        let result = try target.vault.commitBackupImport(plan, using: .allow)
        XCTAssertEqual(result.additions, plan.additions)
        XCTAssertEqual(result.createdGroups, plan.createdGroups)
        XCTAssertEqual(result.renamed, [])

        // Exporting the target again gives the source's document, except that
        // the import time is every updated time and Allow became Ask.
        try target.vault.beginManagementSession(using: .allow)
        let reexport = try target.vault.exportBackup(using: .allow)
        let original = try BackupFileForge.document(of: export)
        let imported = try BackupFileForge.document(of: reexport)
        XCTAssertEqual(imported["groups"] as? [String], original["groups"] as? [String])
        var expected = try XCTUnwrap(original["credentials"] as? [[String: Any]])
        for index in expected.indices {
            expected[index]["updatedAt"] = "2026-01-03T03:04:05Z"
            if expected[index]["permission"] as? String == "allowed" { expected[index]["permission"] = "ask" }
        }
        XCTAssertEqual(NSArray(array: try XCTUnwrap(imported["credentials"] as? [[String: Any]])), NSArray(array: expected))

        let sourceView = try BackupImportLibraryView(source.vault)
        let targetView = try BackupImportLibraryView(target.vault)
        XCTAssertEqual(targetView.active.map(\.name), sourceView.active.map(\.name))
        XCTAssertEqual(targetView.recycled.map(\.deletedAt), [SyntheticBackupLibrary.recycledAt])
        XCTAssertTrue(Set((sourceView.active + sourceView.recycled).map(\.id))
            .isDisjoint(with: (targetView.active + targetView.recycled).map(\.id)))
    }

    func testPermissionsNeverWidenAndImportedVisibleCredentialsReachTheAgentCatalog() throws {
        let source = try makeLibrary(with: [
            .text("Was Allow", "synthetic-allow", permission: .allowed),
            .text("Was Ask", "synthetic-ask"),
            .text("Was Hidden", "synthetic-hidden", permission: .hidden),
            .text("Was Recycled", "synthetic-recycled", permission: .allowed, recycled: true),
        ])
        let export = try source.vault.exportBackup(using: .allow)
        let target = try makeLibrary()
        _ = try target.vault.commitBackupImport(try plan(export, into: target.vault), using: .allow)

        try target.vault.beginManagementSession(using: .allow)
        let view = try BackupImportLibraryView(target.vault)
        XCTAssertEqual(view.active.map(\.name), ["Was Allow", "Was Ask", "Was Hidden"])
        XCTAssertEqual(view.active.map(\.permission), [.ask, .ask, .hidden])
        XCTAssertEqual(view.recycled.map(\.permission), [.ask])
        XCTAssertEqual(try target.vault.brokerCredentialCatalog().map(\.name), ["Was Allow", "Was Ask"])
    }

    // MARK: - Non-empty library

    /// A backup with missing, identical and conflicting credentials, and a
    /// target that already holds some of them.
    private func makeMergeLibraries() throws -> (source: AgentAccessPolicyLibrary, export: BackupExport,
                                                  target: AgentAccessPolicyLibrary) {
        let pem = Data("synthetic-pem".utf8)
        let source = try makeLibrary(with: [
            .text("Missing Token", "synthetic-missing", group: "Shared Ops"),
            .init(name: "Same Token", material: .text("synthetic-same", mapping: "SAME_TOKEN"), usage: "synthetic-usage",
                  notes: "synthetic-notes", group: "Shared Ops", permission: .allowed),
            .init(name: "File Same", material: .file(filename: "same.pem", bytes: pem, mapping: "SAME_FILE")),
            .init(name: "File Renamed", material: .file(filename: "renamed.pem", bytes: pem)),
            .init(name: "Bundle Same", material: .bundle([
                .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("BUNDLE_USER")),
                .init(name: "KEY", value: .file(filename: "bundle.key", bytes: pem), delivery: .temporaryFile("BUNDLE_KEY")),
            ])),
            .text("Conflict Token", "synthetic-conflict-backup"),
            .text("Numbered Token", "synthetic-numbered-backup"),
            .text("Hidden Conflict", "synthetic-hidden-backup"),
            .text(Self.longName, "synthetic-long-backup"),
            .text("Shared", "synthetic-shared-backup"),
            .text("Shared (from backup)", "synthetic-shared-backup-copy"),
        ], groups: ["Fresh Empty"])
        let target = try makeLibrary(with: [
            // Same content, different spelling, group, permission and expiry.
            .init(name: "same token", material: .text("synthetic-same", mapping: "SAME_TOKEN"), usage: "synthetic-usage",
                  notes: "synthetic-notes", group: "shared ops", permission: .hidden, expiresAt: Date(timeIntervalSince1970: 1)),
            .init(name: "File Same", material: .file(filename: "same.pem", bytes: pem, mapping: "SAME_FILE")),
            .init(name: "File Renamed", material: .file(filename: "other.pem", bytes: pem)),
            .init(name: "Bundle Same", material: .bundle([
                .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("BUNDLE_USER")),
                .init(name: "KEY", value: .file(filename: "bundle.key", bytes: pem), delivery: .temporaryFile("BUNDLE_KEY")),
            ]), permission: .allowed),
            .text("Conflict Token", "synthetic-conflict-target", permission: .allowed),
            .text("Numbered Token", "synthetic-numbered-target"),
            .text("Numbered Token (from backup)", "synthetic-numbered-candidate", group: "Target Group"),
            .text("Hidden Conflict", "synthetic-hidden-target", permission: .hidden),
            .text(Self.longName, "synthetic-long-target"),
            .text("Shared", "synthetic-shared-target", notes: "synthetic-target-notes", recycled: true),
        ])
        return (source, try source.vault.exportBackup(using: .allow), target)
    }

    private let expectedMergeRenames = [
        "Missing Token": "Missing Token",
        "Conflict Token": "Conflict Token (from backup)",
        "File Renamed": "File Renamed (from backup)",
        "Numbered Token": "Numbered Token (from backup 2)",
        "Hidden Conflict": "Hidden Conflict (from backup)",
        longName: String(longName.prefix(241)) + " (from backup)",
        // The backup's own "Shared (from backup)" keeps its name, so the
        // conflicting "Shared" takes the next candidate.
        "Shared (from backup)": "Shared (from backup)",
        "Shared": "Shared (from backup 2)",
    ]

    func testMergeAddsMissingSkipsIdenticalAndRenamesConflictsWithoutChangingExistingCredentials() throws {
        let (_, export, target) = try makeMergeLibraries()
        let before = try BackupImportLibraryView(target.vault)

        let plan = try plan(export, into: target.vault)
        XCTAssertEqual(renames(plan.additions), expectedMergeRenames)
        XCTAssertEqual(Set(plan.renamed.map(\.backupName)),
                       ["Conflict Token", "File Renamed", "Numbered Token", "Hidden Conflict", Self.longName, "Shared"])
        let longCandidate = try XCTUnwrap(expectedMergeRenames[Self.longName])
        XCTAssertEqual(longCandidate.count, CredentialName.maximumLength)
        XCTAssertEqual(plan.skippedIdentical, [
            .init(backupName: "Bundle Same", name: "Bundle Same"),
            .init(backupName: "File Same", name: "File Same"),
            .init(backupName: "Same Token", name: "same token"),
        ])
        XCTAssertEqual(plan.skippedInRecycleBin, [])
        XCTAssertEqual(plan.skippedRecycled, [])
        // "Shared Ops" matches the target's "shared ops"; only the empty group is new.
        XCTAssertEqual(plan.createdGroups, ["Fresh Empty"])

        let counter = CatalogChangeCounter()
        let result = try target.vault.commitBackupImport(plan, using: .allow)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(renames(result.renamed), renames(plan.renamed))

        let after = try BackupImportLibraryView(target.vault)
        for existing in before.active {
            XCTAssertEqual(after.active.first { $0.id == existing.id }, existing, existing.name)
        }
        XCTAssertEqual(after.recycled, before.recycled)
        XCTAssertEqual(after.active.count, before.active.count + expectedMergeRenames.count)
        XCTAssertEqual(after.groups, (before.groups + ["Fresh Empty"]).sorted())
        let conflict = try after.credential(named: "Conflict Token (from backup)")
        XCTAssertEqual(conflict.value, "synthetic-conflict-backup")
        XCTAssertEqual(conflict.permission, .ask)
        XCTAssertEqual(try after.credential(named: longCandidate).value, "synthetic-long-backup")
        XCTAssertEqual(try after.credential(named: "Shared (from backup 2)").value, "synthetic-shared-backup")
        XCTAssertEqual(try after.credential(named: "Shared (from backup)").value, "synthetic-shared-backup-copy")
        XCTAssertEqual(try after.credential(named: "Missing Token").groupName, "shared ops")
        XCTAssertEqual(try after.credential(named: "File Renamed (from backup)").originalFilename, "renamed.pem")
    }

    func testImportingTheSameBackupTwiceAddsNothingTheSecondTime() throws {
        let (_, export, target) = try makeMergeLibraries()
        _ = try target.vault.commitBackupImport(try plan(export, into: target.vault), using: .allow)
        let afterFirst = try BackupImportLibraryView(target.vault)

        let second = try plan(export, into: target.vault)
        XCTAssertEqual(second.additions, [])
        XCTAssertEqual(second.createdGroups, [])
        // Each renamed credential is now found under its final name.
        let identical = Dictionary(uniqueKeysWithValues: second.skippedIdentical.map { ($0.backupName, $0.name) })
        for (backupName, finalName) in expectedMergeRenames {
            XCTAssertEqual(identical[backupName], finalName, backupName)
        }
        let counter = CatalogChangeCounter()
        XCTAssertEqual(try target.vault.commitBackupImport(second, using: .allow).additions, [])
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(try BackupImportLibraryView(target.vault), afterFirst)
    }

    func testLongBaseNamesAreShortenedForEveryCandidate() throws {
        let wide = String(repeating: "\u{1F512}", count: 250) // Four UTF-8 bytes each.
        let source = try makeLibrary(with: [.text(Self.longName, "synthetic-long-backup"), .text(wide, "synthetic-wide-backup")])
        let target = try makeLibrary(with: [
            .text(Self.longName, "synthetic-long-target"),
            .text(String(Self.longName.prefix(241)) + " (from backup)", "synthetic-long-candidate"),
            .text(wide, "synthetic-wide-target"),
        ])
        let plan = try plan(try source.vault.exportBackup(using: .allow), into: target.vault)
        let numbered = String(Self.longName.prefix(239)) + " (from backup 2)"
        XCTAssertEqual(renames(plan.additions), [
            Self.longName: numbered,
            wide: String(wide.prefix(241)) + " (from backup)",
        ])
        XCTAssertEqual(numbered.count, CredentialName.maximumLength)
        _ = try target.vault.commitBackupImport(plan, using: .allow)
        XCTAssertEqual(try BackupImportLibraryView(target.vault).credential(named: numbered).value, "synthetic-long-backup")
    }

    func testGroupsThatOnlySkippedCredentialsCarryAreNotCreated() throws {
        let source = try makeLibrary(with: [
            .text("Secret Token", "synthetic-secret", group: "Secret Ops", permission: .hidden),
            .text("Archived Token", "synthetic-archived", group: "Archive Ops", recycled: true),
            .text("Carried Token", "synthetic-carried", group: "Carried Ops"),
        ], groups: ["Visible Empty"])
        let target = try makeLibrary(with: [
            .text("Secret Token", "synthetic-secret", permission: .hidden),
            .text("Archived Token", "synthetic-archived-target"),
        ])
        let plan = try plan(try source.vault.exportBackup(using: .allow), into: target.vault)
        XCTAssertEqual(plan.additions.map(\.name), ["Carried Token"])
        XCTAssertEqual(plan.skippedIdentical, [.init(backupName: "Secret Token", name: "Secret Token")])
        XCTAssertEqual(plan.skippedRecycled, ["Archived Token"])
        XCTAssertEqual(plan.createdGroups, ["Carried Ops", "Visible Empty"])

        _ = try target.vault.commitBackupImport(plan, using: .allow)
        XCTAssertEqual(try target.vault.listCredentialGroups(), ["Carried Ops", "Visible Empty"])
        XCTAssertEqual(try target.vault.brokerCredentialGroups(), ["Carried Ops", "Visible Empty"])
    }

    // MARK: - Recycle Bin

    func testRecycledCredentialsThatConflictOrOutlivedRetentionAreSkippedAndRecycleBinCopiesReported() throws {
        let day: TimeInterval = 24 * 60 * 60
        let start = SyntheticBackupLibrary.createdAt
        let sourceClock = BackupTestClock(start)
        let source = try makeLibrary(with: [.text("Old Recycled", "synthetic-old", recycled: true)], now: { sourceClock.now })
        sourceClock.now = start.addingTimeInterval(20 * day)
        try source.vault.beginManagementSession(using: .allow)
        for credential: SyntheticCredential in [
            .text("Fresh Recycled", "synthetic-fresh", group: "Recycled Group", recycled: true),
            .text("Conflicting Recycled", "synthetic-conflicting", recycled: true),
            .text("Twin", "synthetic-twin-backup"),
            .text("Twin (from backup)", "synthetic-twin-recycled", recycled: true),
            .text("Restorable", "synthetic-restorable"),
            .text("Restorable Candidate", "synthetic-restorable-candidate"),
        ] { try credential.create(in: source.vault) }
        let export = try source.vault.exportBackup(using: .allow)

        let targetClock = BackupTestClock(start.addingTimeInterval(31 * day))
        let target = try makeLibrary(with: [
            .text("Conflicting Recycled", "synthetic-conflicting-target"),
            .text("Twin", "synthetic-twin-target"),
            .text("Restorable", "synthetic-restorable", recycled: true),
            .text("Restorable Candidate", "synthetic-restorable-candidate-target"),
            .text("Restorable Candidate (from backup)", "synthetic-restorable-candidate", recycled: true),
        ], now: { targetClock.now })
        let before = try BackupImportLibraryView(target.vault)

        let plan = try plan(export, into: target.vault)
        XCTAssertEqual(plan.additions, [
            .init(backupName: "Fresh Recycled", name: "Fresh Recycled", isRecycled: true),
            .init(backupName: "Twin", name: "Twin (from backup)", isRecycled: false),
        ])
        XCTAssertEqual(plan.skippedInRecycleBin, [
            .init(backupName: "Restorable", name: "Restorable"),
            .init(backupName: "Restorable Candidate", name: "Restorable Candidate (from backup)"),
        ])
        // Name taken by the target, retention ended, name taken by this import.
        XCTAssertEqual(plan.skippedRecycled, ["Conflicting Recycled", "Old Recycled", "Twin (from backup)"])
        XCTAssertEqual(plan.skippedIdentical, [])
        XCTAssertEqual(plan.createdGroups, ["Recycled Group"])

        _ = try target.vault.commitBackupImport(plan, using: .allow)
        let after = try BackupImportLibraryView(target.vault)
        XCTAssertEqual(after.active.count, before.active.count + 1)
        let fresh = try after.credential(named: "Fresh Recycled")
        XCTAssertEqual(fresh.deletedAt, start.addingTimeInterval(20 * day))
        XCTAssertEqual(fresh.groupName, "Recycled Group")
        XCTAssertEqual(Set(after.recycled.map(\.name)), Set(before.recycled.map(\.name) + ["Fresh Recycled"]))
        XCTAssertEqual(after.groups, ["Recycled Group"])
        XCTAssertFalse(try target.vault.brokerCredentialCatalog().map(\.name).contains("Fresh Recycled"))
    }
}
