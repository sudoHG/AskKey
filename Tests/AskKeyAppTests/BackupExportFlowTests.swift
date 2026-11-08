import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class BackupExportFlowTests: BackupFlowTestCase {
    private let backupDate = Date(timeIntervalSince1970: 1_793_016_000) // 2026-10-26T12:00:00Z

    func testExportAuthenticatesFirstAndWritesOnlyAfterTheLastGroupIsConfirmed() async throws {
        let fixture = try makeFixture()
        try fixture.text("Staging API", "synthetic-staging-value", in: fixture.source)
        try fixture.openManagement(in: fixture.source)
        let flow = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations, now: { self.backupDate })

        let started = await flow.start()

        XCTAssertTrue(started)
        XCTAssertEqual(fixture.prompts.reasons, [CredentialManagementCopy.exportBackupReason])
        let key = try XCTUnwrap(flow.recoveryKey)
        XCTAssertNotNil(key.range(of: #"\A[0-9A-Z]{4}(-[0-9A-Z]{4}){6}\z"#, options: .regularExpression))
        XCTAssertEqual(flow.recoveryKeyGroups.count, 7)
        XCTAssertEqual(fixture.disk.savePanelNames, [], "the save panel waits for the last group")

        flow.confirmation = "ZZZZ"
        XCTAssertFalse(flow.isConfirmed)
        XCTAssertFalse(flow.save())
        XCTAssertEqual(fixture.disk.savePanelNames, [])
        XCTAssertEqual(fixture.disk.writes, [])

        // Typed the way a recovery key is read: any case, with spaces.
        let last = try XCTUnwrap(flow.recoveryKeyGroups.last)
        flow.confirmation = " " + last.lowercased().map(String.init).joined(separator: " ")
        XCTAssertTrue(flow.isConfirmed)
        let destination = URL(fileURLWithPath: "/synthetic/Chosen.askkeybackup")
        fixture.disk.exportDestination = destination
        XCTAssertTrue(flow.save())

        XCTAssertEqual(fixture.disk.savePanelNames, ["Ask Key Backup 2026-10-26.askkeybackup"])
        XCTAssertEqual(fixture.disk.writes, [destination])
        XCTAssertEqual(flow.savedFileName, "Chosen.askkeybackup")
        XCTAssertNil(flow.recoveryKey, "the key is discarded once the file is written")
        let written = try XCTUnwrap(fixture.disk.files[destination])
        XCTAssertEqual(try fixture.target.inspectBackup(written, recoveryKey: key).credentialCount, 1)
        XCTAssertEqual(fixture.prompts.reasons.count, 1)
    }

    func testCancelledOrFailedAuthenticationShowsNoKeyAndWritesNothing() async throws {
        let fixture = try makeFixture()
        try fixture.openManagement(in: fixture.source)
        let flow = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations)

        fixture.prompts.result = .cancelled
        let cancelled = await flow.start()
        XCTAssertFalse(cancelled)
        XCTAssertNil(flow.recoveryKey)
        XCTAssertNil(fixture.viewModel.errorMessage)

        fixture.prompts.result = .failed
        let failed = await flow.start()
        XCTAssertFalse(failed)
        XCTAssertNil(flow.recoveryKey)
        XCTAssertEqual(fixture.viewModel.errorMessage, "System authentication failed.")

        XCTAssertEqual(fixture.prompts.reasons, Array(repeating: CredentialManagementCopy.exportBackupReason, count: 2))
        XCTAssertEqual(fixture.disk.savePanelNames, [])
        XCTAssertEqual(fixture.disk.writes, [])
    }

    func testExportNeedsAnUnlockedManagementSessionBeforeAnyPrompt() async throws {
        let fixture = try makeFixture()
        let flow = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations)

        let started = await flow.start()

        XCTAssertFalse(started)
        XCTAssertEqual(fixture.prompts.reasons, [])
        XCTAssertEqual(fixture.viewModel.errorMessage,
                       "Credential management requires confirmation before it can continue.")
        XCTAssertEqual(fixture.disk.writes, [])
    }

    func testCancellingAtEveryStepWritesNothing() async throws {
        let fixture = try makeFixture()
        try fixture.openManagement(in: fixture.source)
        let flow = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations)

        // Cancel on the recovery key sheet.
        _ = await flow.start()
        XCTAssertNotNil(flow.recoveryKey)
        flow.cancel()
        XCTAssertNil(flow.recoveryKey)
        XCTAssertFalse(flow.save())

        // Cancel the save panel: the key stays on screen, then cancel the sheet.
        _ = await flow.start()
        flow.confirmation = try XCTUnwrap(flow.recoveryKeyGroups.last)
        fixture.disk.exportDestination = nil
        XCTAssertFalse(flow.save())
        XCTAssertEqual(fixture.disk.savePanelNames.count, 1)
        XCTAssertNotNil(flow.recoveryKey)
        flow.cancel()

        XCTAssertEqual(fixture.disk.writes, [])
        XCTAssertNil(flow.savedFileName)
    }

    func testFailedWriteLeavesNoFileShowsAnErrorAndKeepsTheKey() async throws {
        let fixture = try makeFixture()
        try fixture.openManagement(in: fixture.source)
        let missing = try fixture.makeDirectory("parent").appendingPathComponent("missing/Backup.askkeybackup")
        fixture.disk.write = BackupFileStorage.write
        let flow = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations)
        _ = await flow.start()
        flow.confirmation = try XCTUnwrap(flow.recoveryKeyGroups.last)
        fixture.disk.exportDestination = missing

        XCTAssertFalse(flow.save())

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(flow.errorMessage,
                       "The backup could not be saved there, and no file was written. Choose another location and try again.")
        XCTAssertNotNil(flow.recoveryKey, "the person can choose another location")
        XCTAssertNil(flow.savedFileName)
    }

    func testFileStorageWritesOwnerOnlyFilesAtomically() throws {
        let fixture = try makeFixture()
        let directory = try fixture.makeDirectory("disk")
        let destination = directory.appendingPathComponent("Backup.askkeybackup")

        try BackupFileStorage.write(Data("first".utf8), to: destination)
        try BackupFileStorage.write(Data("second".utf8), to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Backup.askkeybackup"])

        let readOnly = try fixture.makeDirectory("read-only")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        XCTAssertThrowsError(try BackupFileStorage.write(Data("third".utf8), to: readOnly.appendingPathComponent("B.askkeybackup")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: readOnly.path), [])
    }

    func testDefaultFileNameCarriesOnlyTheDate() throws {
        _ = try makeFixture(language: "en")
        XCTAssertEqual(VaultViewModel.backupFileName(on: backupDate), "Ask Key Backup 2026-10-26.askkeybackup")
    }
}
