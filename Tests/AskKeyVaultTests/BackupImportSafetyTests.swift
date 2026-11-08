import Foundation
import GRDB
import XCTest
@testable import AskKeyVault

/// What import planning requires, and what leaves the target library unchanged.
final class BackupImportSafetyTests: BackupImportTestCase {
    private var export: BackupExport!

    override func setUpWithError() throws {
        let source = try makeLibrary()
        try SyntheticBackupLibrary.populate(source.vault)
        export = try source.vault.exportBackup(using: .allow)
    }

    /// A target with one credential and one group, and a management session.
    private func makeTarget(now: @escaping () -> Date = Date.init) throws -> AgentAccessPolicyLibrary {
        try makeLibrary(with: [.text("Existing Token", "synthetic-existing", group: "Existing Group")], now: now)
    }

    private func assertRefused<T>(_ expression: @autoclosure () throws -> T, _ expected: BackupImportError,
                                  _ message: String = "", line: UInt = #line) {
        XCTAssertThrowsError(try expression(), message, line: line) { error in
            XCTAssertEqual(error as? BackupImportError, expected, "\(message): \(error)", line: line)
        }
    }

    private func assertManagementRequired<T>(_ expression: @autoclosure () throws -> T, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { error in
            guard case VaultError.managementAuthenticationRequired = error else { return XCTFail("\(error)", line: line) }
        }
    }

    // MARK: - Planning

    func testPlanNeedsASessionOnceTheLibraryHasCredentials() throws {
        let empty = try makeLibrary()
        XCTAssertEqual(try plan(export, into: empty.vault).additions.count, 6)

        let active = try makeTarget()
        active.vault.endManagementSession()
        assertManagementRequired(try plan(export, into: active.vault))
        try active.vault.beginManagementSession(using: .allow)
        XCTAssertEqual(try plan(export, into: active.vault).additions.count, 6)

        let recycledOnly = try makeLibrary(with: [.text("Recycled", "synthetic-recycled", recycled: true)])
        recycledOnly.vault.endManagementSession()
        assertManagementRequired(try plan(export, into: recycledOnly.vault))

        empty.vault.lock()
        XCTAssertThrowsError(try plan(export, into: empty.vault)) { error in
            guard case VaultError.vaultLocked = error else { return XCTFail("\(error)") }
        }
    }

    func testPlanRefusesTheFilesThatInspectionRefuses() throws {
        let target = try makeLibrary()
        var symbols = Array(export.recoveryKey.groupedText)
        symbols[0] = symbols[0] == "A" ? "B" : "A"
        XCTAssertThrowsError(try target.vault.planBackupImport(Data(), recoveryKey: String(symbols),
                                                              renameSuffix: backupRenameSuffix)) { error in
            XCTAssertEqual(error as? BackupRecoveryKeyError, .checksumMismatch)
        }
        XCTAssertBackupError(try target.vault.planBackupImport(export.fileBytes.dropLast(),
            recoveryKey: export.recoveryKey.groupedText, renameSuffix: backupRenameSuffix), .cannotOpen)
        let duplicate = try BackupFileForge.rewriteCredentials(export) { credentials in
            credentials[try BackupFileForge.index(of: "Synthetic Hidden Token", in: credentials)]["name"] = "synthetic alpha token"
        }
        XCTAssertBackupError(try target.vault.planBackupImport(duplicate, recoveryKey: export.recoveryKey.groupedText,
            renameSuffix: backupRenameSuffix), .invalidContents(.duplicateCredentialName))
        XCTAssertEqual(try target.vault.storedCredentialCount(), 0)
    }

    func testRenameSuffixMustFormADistinctValidName() throws {
        let target = try makeLibrary(with: [
            .text("Synthetic Alpha Token", "synthetic-target-alpha"),
            .text("Synthetic Alpha Token (from backup)", "synthetic-target-candidate"),
        ])
        let suffixes: [(String, (Int) -> String)] = [
            ("blank", { _ in "  " }), ("control", { _ in "(from\u{7}backup)" }), ("repeated", { _ in "(from backup)" }),
            ("too long", { _ in String(repeating: "s", count: 256) }),
        ]
        for (label, suffix) in suffixes {
            assertRefused(try plan(export, into: target.vault, renameSuffix: suffix), .invalidRenameSuffix, label)
        }
        XCTAssertEqual(renames(try plan(export, into: target.vault).renamed),
                       ["Synthetic Alpha Token": "Synthetic Alpha Token (from backup 2)"])
    }

    func testPrintingOrDumpingAPlanShowsNoValues() throws {
        let plan = try plan(export, into: try makeLibrary().vault)
        var dumped = ""
        dump(plan, to: &dumped)
        for text in ["\(plan)", String(reflecting: plan), dumped] {
            for value in ["synthetic-alpha-value", "synthetic-alpha-notes", "synthetic-db-password", "synthetic-deploy-key-bytes"] {
                XCTAssertFalse(text.contains(value), value)
            }
        }
        XCTAssertTrue(dumped.contains("Synthetic Alpha Token"), dumped)
    }

    // MARK: - Commit leaves the library unchanged

    func testStorageFailureAfterTheFirstInsertLeavesNoImportedCredentialOrGroup() throws {
        let target = try makeTarget()
        let before = try BackupImportLibraryView(target.vault)
        let plan = try plan(export, into: target.vault)
        let triggers = [
            ("reject_second_import", "BEFORE INSERT ON credentials WHEN (SELECT COUNT(*) FROM credentials) > 1"),
            ("reject_import_groups", "BEFORE INSERT ON config WHEN NEW.key = 'credential_groups'"),
        ]
        for (name, condition) in triggers {
            try target.store.db.write { db in
                try db.execute(sql: "CREATE TRIGGER \(name) \(condition) BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
            }
            let counter = CatalogChangeCounter()
            XCTAssertThrowsError(try target.vault.commitBackupImport(plan, using: .allow), name) { error in
                XCTAssertTrue(error is DatabaseError, "\(error)")
            }
            XCTAssertEqual(counter.count, 0, name)
            XCTAssertEqual(try BackupImportLibraryView(target.vault), before, name)
            XCTAssertEqual(try target.vault.storedCredentialCount(), 1, name)
            try target.store.db.write { try $0.execute(sql: "DROP TRIGGER \(name)") }
        }
        // Nothing was written, so the same plan still commits.
        XCTAssertEqual(try target.vault.commitBackupImport(plan, using: .allow).additions.count, 6)
        XCTAssertEqual(try target.vault.storedCredentialCount(), 7)
    }

    func testLibraryChangeBetweenPlanAndCommitIsRefusedBeforeAuthentication() throws {
        let changes: [(String, (Vault) throws -> Void)] = [
            ("create credential", { _ = try $0.createTextCredential(.init(name: "Later", value: "synthetic-later"), using: .allow) }),
            ("create group", { try $0.createCredentialGroup("Later Group", using: .allow) }),
            ("change permission", { vault in
                let existing = try XCTUnwrap(vault.listTextCredentials().first)
                try vault.updateCredentialPermission(id: existing.id, permission: .hidden, using: .allow)
            }),
            ("recycle", { vault in
                try vault.deleteTextCredential(id: try XCTUnwrap(vault.listTextCredentials().first).id, using: .allow)
            }),
        ]
        for (label, change) in changes {
            let target = try makeTarget()
            let plan = try plan(export, into: target.vault)
            try change(target.vault)
            let changed = try BackupImportLibraryView(target.vault)
            let prompts = BackupPromptRecorder()
            assertRefused(try target.vault.commitBackupImport(plan, using: prompts.authenticator(result: true)),
                          .libraryChanged, label)
            XCTAssertEqual(prompts.reasons, [], label)
            XCTAssertEqual(try BackupImportLibraryView(target.vault), changed, label)
        }
    }

    func testPlanCommitsOnlyIntoTheLibraryItWasMadeFor() throws {
        let planned = try makeLibrary()
        let other = try makeLibrary()
        let plan = try plan(export, into: planned.vault)
        // Both libraries are empty, but their App keys differ.
        assertRefused(try other.vault.commitBackupImport(plan, using: .allow), .libraryChanged)
        XCTAssertEqual(try other.vault.storedCredentialCount(), 0)
    }

    func testRecycledCredentialWhoseRetentionEndsBeforeCommitMakesThePlanStale() throws {
        let sourceClock = BackupTestClock(SyntheticBackupLibrary.createdAt)
        let source = try makeLibrary(now: { sourceClock.now })
        try SyntheticBackupLibrary.populate(source.vault, clock: sourceClock)
        let export = try source.vault.exportBackup(using: .allow)
        let targetClock = BackupTestClock(SyntheticBackupLibrary.recycledAt)
        let target = try makeLibrary(now: { targetClock.now })
        let stale = try plan(export, into: target.vault)
        XCTAssertEqual(stale.additions.filter(\.isRecycled).count, 1)

        targetClock.now = SyntheticBackupLibrary.recycledAt.addingTimeInterval(BackupImportPlanner.recycleBinRetention)
        assertRefused(try target.vault.commitBackupImport(stale, using: .allow), .libraryChanged)
        XCTAssertEqual(try target.vault.storedCredentialCount(), 0)
        XCTAssertEqual(try plan(export, into: target.vault).skippedRecycled, ["Synthetic Recycled Token"])
    }

    func testCommitWithoutASessionOrWithCancelledAuthenticationChangesNothing() throws {
        let target = try makeTarget()
        let before = try BackupImportLibraryView(target.vault)
        let plan = try plan(export, into: target.vault)

        target.vault.endManagementSession()
        let unauthenticated = BackupPromptRecorder()
        assertManagementRequired(try target.vault.commitBackupImport(plan, using: unauthenticated.authenticator(result: true)))
        XCTAssertEqual(unauthenticated.reasons, [])

        try target.vault.beginManagementSession(using: .allow)
        let cancelled = BackupPromptRecorder()
        assertManagementRequired(try target.vault.commitBackupImport(plan, using: cancelled.authenticator(result: false)))
        XCTAssertEqual(cancelled.reasons, [CredentialManagementCopy.importBackupReason])
        XCTAssertEqual(try BackupImportLibraryView(target.vault), before)

        let confirmed = BackupPromptRecorder()
        XCTAssertEqual(try target.vault.commitBackupImport(plan, using: confirmed.authenticator(result: true)).additions.count, 6)
        XCTAssertEqual(confirmed.reasons, [CredentialManagementCopy.importBackupReason])
    }

    func testEmptyLibraryCommitStillNeedsFreshAuthentication() throws {
        let target = try makeLibrary()
        let plan = try plan(export, into: target.vault)
        let cancelled = BackupPromptRecorder()
        assertManagementRequired(try target.vault.commitBackupImport(plan, using: cancelled.authenticator(result: false)))
        XCTAssertEqual(cancelled.reasons, [CredentialManagementCopy.importBackupReason])
        XCTAssertEqual(try target.vault.storedCredentialCount(), 0)

        let confirmed = BackupPromptRecorder()
        _ = try target.vault.commitBackupImport(plan, using: confirmed.authenticator(result: true))
        XCTAssertEqual(confirmed.reasons, [CredentialManagementCopy.importBackupReason])
        XCTAssertEqual(try target.vault.storedCredentialCount(), 6)
        XCTAssertFalse(target.vault.hasActiveManagementSession)
    }
}
