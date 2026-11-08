import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class BackupImportFlowTests: BackupFlowTestCase {
    private let typoMessage = "This recovery key has a typo. Check each group of four characters and try again."
    private let cannotOpenMessage = "This recovery key doesn't open this file, or the file is damaged."
    private let newerMessage = "This backup was made by a newer version of Ask Key. Update Ask Key, then try again."

    /// Source: "Staging API" and "Build Cache". Target: a different "Staging API".
    private func conflictingLibraries() throws -> (BackupFlowFixture, recoveryKey: String) {
        let fixture = try makeFixture()
        try fixture.text("Staging API", "synthetic-source-value", in: fixture.source)
        try fixture.text("Build Cache", "synthetic-cache-value", in: fixture.source)
        let (_, recoveryKey) = try fixture.sourceBackup()
        try fixture.text("Staging API", "synthetic-target-value", in: fixture.target)
        try fixture.openManagement(in: fixture.target)
        return (fixture, recoveryKey)
    }

    func testImportShowsThePreviewBeforeAuthenticationAndCommitsOnlyAfterIt() async throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)

        XCTAssertTrue(flow.chooseFile())
        XCTAssertEqual(flow.fileName, "Ask Key Backup 2026-11-08.askkeybackup")
        XCTAssertEqual(flow.stage, .enteringKey)
        flow.recoveryKey = recoveryKey.lowercased()
        XCTAssertTrue(flow.openBackup())

        XCTAssertEqual(flow.stage, .preview)
        let plan = try XCTUnwrap(flow.plan)
        XCTAssertEqual(Set(plan.additions.map(\.name)), ["Staging API (from backup)", "Build Cache"])
        XCTAssertEqual(plan.renamed.map(\.name), ["Staging API (from backup)"])
        XCTAssertEqual(fixture.prompts.reasons, [], "the preview needs no authentication")
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 1, "the preview writes nothing")

        let committed = await flow.confirm()

        XCTAssertTrue(committed)
        XCTAssertEqual(fixture.prompts.reasons, [CredentialManagementCopy.importBackupReason])
        XCTAssertEqual(flow.stage, .result)
        XCTAssertEqual(flow.result?.renamed.map(\.name), ["Staging API (from backup)"])
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 3)
        XCTAssertEqual(flow.recoveryKey, "", "the key is discarded after the import")
        flow.finish()
        XCTAssertEqual(fixture.viewModel.onboardingCredentialCount, 3)
    }

    func testCancelledAuthenticationKeepsThePreviewAndWritesNothing() async throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(flow.chooseFile())
        flow.recoveryKey = recoveryKey
        XCTAssertTrue(flow.openBackup())

        fixture.prompts.result = .cancelled
        let cancelled = await flow.confirm()
        XCTAssertFalse(cancelled)
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertNil(flow.errorMessage)

        fixture.prompts.result = .failed
        let failed = await flow.confirm()
        XCTAssertFalse(failed)
        XCTAssertEqual(flow.errorMessage, "System authentication failed.")
        XCTAssertNil(fixture.viewModel.errorMessage, "the error shows in the sheet, not behind it")

        flow.cancel()
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 1)
        XCTAssertEqual(fixture.prompts.reasons.count, 2)
    }

    func testCancellingThePanelOrTheKeyEntryWritesNothing() throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        let file = fixture.disk.importFile

        fixture.disk.importFile = nil
        XCTAssertFalse(flow.chooseFile())
        fixture.disk.importFile = file
        XCTAssertTrue(flow.chooseFile())
        flow.recoveryKey = recoveryKey
        flow.cancel()

        XCTAssertFalse(flow.openBackup())
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 1)
        XCTAssertEqual(fixture.prompts.reasons, [])
    }

    func testAStalePlanShowsANewPreviewInsteadOfCommitting() async throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(flow.chooseFile())
        flow.recoveryKey = recoveryKey
        XCTAssertTrue(flow.openBackup())
        XCTAssertFalse(flow.planWasRefreshed)

        // The library changes after the preview: the backup's "Build Cache" now conflicts too.
        _ = try fixture.target.createTextCredential(.init(name: "Build Cache", value: "synthetic-late-value"), using: .allow)
        let stale = await flow.confirm()

        XCTAssertFalse(stale)
        XCTAssertEqual(flow.stage, .preview)
        XCTAssertTrue(flow.planWasRefreshed)
        XCTAssertEqual(Set(flow.plan?.renamed.map(\.name) ?? []),
                       ["Staging API (from backup)", "Build Cache (from backup)"])
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 2, "the stale plan wrote nothing")

        let committed = await flow.confirm()
        XCTAssertTrue(committed)
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 4)
        XCTAssertEqual(fixture.prompts.reasons, Array(repeating: CredentialManagementCopy.importBackupReason, count: 2))
    }

    func testTypoWrongKeyOrDamagedFileAndNewerFormatHaveDistinctMessages() throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let file = try XCTUnwrap(fixture.disk.importFile)
        let original = try XCTUnwrap(fixture.disk.files[file])
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(flow.chooseFile())

        func attempt(_ key: String) -> String? {
            flow.recoveryKey = key
            XCTAssertFalse(flow.openBackup())
            XCTAssertEqual(flow.stage, .enteringKey)
            return flow.keyMessage
        }

        let first = recoveryKey.first!
        let typo = String(first == "A" ? "B" : "A") + recoveryKey.dropFirst()
        XCTAssertEqual(attempt(typo), typoMessage)
        XCTAssertEqual(attempt(String(recoveryKey.dropLast(5))), typoMessage)

        try fixture.source.beginManagementSession(using: .allow)
        let otherKey = try fixture.source.exportBackup(using: .allow).recoveryKey.groupedText
        XCTAssertEqual(attempt(otherKey), cannotOpenMessage)

        var damaged = original
        damaged[damaged.count - 1] ^= 0x01
        fixture.disk.files[file] = damaged
        XCTAssertTrue(flow.chooseFile())
        XCTAssertEqual(attempt(recoveryKey), cannotOpenMessage)

        var newer = original
        newer[13] = 2 // The big-endian format version follows the 12-byte magic.
        fixture.disk.files[file] = newer
        XCTAssertTrue(flow.chooseFile())
        XCTAssertEqual(attempt(recoveryKey), newerMessage)

        XCTAssertEqual(try fixture.target.storedCredentialCount(), 1)
        XCTAssertEqual(fixture.prompts.reasons, [])
    }

    func testEmptyLibraryRestoresFromTheFirstRunScreenWithoutCreatingACredential() async throws {
        let fixture = try makeFixture()
        try fixture.text("Staging API", "synthetic-source-value", in: fixture.source)
        try fixture.text("Build Cache", "synthetic-cache-value", in: fixture.source)
        let (_, recoveryKey) = try fixture.sourceBackup()
        XCTAssertEqual(fixture.viewModel.onboardingCredentialCount, 0)
        XCTAssertFalse(fixture.viewModel.hasManagementSession)

        // Restore from Backup… on the first-run screen uses the first-run allowance.
        XCTAssertTrue(fixture.viewModel.beginBackupRestore())
        XCTAssertFalse(fixture.viewModel.hasManagementSession)
        XCTAssertFalse(fixture.target.hasActiveManagementSession)
        let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(flow.chooseFile())
        flow.recoveryKey = recoveryKey
        XCTAssertTrue(flow.openBackup())
        XCTAssertEqual(flow.plan?.additions.count, 2)
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 0, "no credential is created before the commit")
        XCTAssertEqual(fixture.prompts.reasons, [])

        let committed = await flow.confirm()

        XCTAssertTrue(committed)
        XCTAssertEqual(fixture.prompts.reasons, [CredentialManagementCopy.importBackupReason])
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 2)
        XCTAssertFalse(fixture.target.hasActiveManagementSession, "a restore does not unlock management")
        flow.finish()
        XCTAssertEqual(fixture.viewModel.onboardingCredentialCount, 2)
    }

    func testABackupAlreadyImportedHasNothingToImportAndNeverPrompts() async throws {
        let (fixture, recoveryKey) = try conflictingLibraries()
        let first = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(first.chooseFile())
        first.recoveryKey = recoveryKey
        XCTAssertTrue(first.openBackup())
        let committed = await first.confirm()
        XCTAssertTrue(committed)

        let again = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
        XCTAssertTrue(again.chooseFile())
        again.recoveryKey = recoveryKey
        XCTAssertTrue(again.openBackup())
        XCTAssertTrue(again.hasNothingToImport)
        let repeated = await again.confirm()

        XCTAssertFalse(repeated)
        XCTAssertEqual(fixture.prompts.reasons.count, 1)
        XCTAssertEqual(try fixture.target.storedCredentialCount(), 3)
    }

    func testRenameSuffixFollowsTheLanguageAndNumbersLaterCandidates() {
        let english = VaultViewModel.backupRenameSuffix(language: "en")
        XCTAssertEqual(english(1), "(from backup)")
        XCTAssertEqual(english(2), "(from backup 2)")
        let chinese = VaultViewModel.backupRenameSuffix(language: "zh-Hans")
        XCTAssertEqual(chinese(1), AppLanguage.localized("(from backup)", language: "zh-Hans"))
        XCTAssertNotEqual(chinese(1), english(1))
        XCTAssertTrue(chinese(3).hasSuffix("3)"))
    }
}
