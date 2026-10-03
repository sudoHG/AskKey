import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

final class CursorBackupRollbackTests: CursorUserMCPAdapterTests {
    func testBackupIsOwnerOnlySingleCopyAndRemovedAfterSuccessfulConnection() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o644)
        _ = try harness.adapter.apply()

        XCTAssertEqual(try harness.permissions(harness.backupDirectory), 0o700)
        XCTAssertEqual(try harness.permissions(harness.backupURL), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: harness.backupDirectory.path),
            [harness.backupURL.lastPathComponent]
        )

        try harness.withBroker { _ in
            let status = try harness.adapter.verify()
            XCTAssertTrue(status.connected)
            XCTAssertTrue(status.configReady)
            XCTAssertTrue(status.helperReady)
            XCTAssertTrue(status.protocolReady)
            XCTAssertTrue(status.brokerHealthy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }
    func testCleanupFailureThenUserEditUsesTheNewConfigAsRetryBaseline() throws {
        var cleanupFails = true
        let harness = try makeHarness(removeBackupItem: { url in
            if cleanupFails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        _ = try harness.adapter.apply()

        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify()) { error in
                XCTAssertEqual(error as? CursorMCPError, .backupCleanupFailed)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))

        let userEdit = Data(#"{"mcpServers":{"user-edit":{"command":"true"}}}"#.utf8)
        try harness.writeUserConfig(userEdit, permissions: 0o640)
        cleanupFails = false
        _ = try harness.adapter.apply()
        XCTAssertFalse(try harness.adapter.verify().connected)
        try harness.adapter.rollback()

        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), userEdit)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
    func testConnectedConfigWithoutAManagedBackupStillVerifies() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try FileManager.default.removeItem(at: harness.backupURL)

        try harness.withBroker { _ in
            XCTAssertTrue(try harness.adapter.verify().connected)
        }
    }
    func testCleanupFailureThenPermissionEditUsesTheNewModeAsRetryBaseline() throws {
        var cleanupFails = true
        let harness = try makeHarness(removeBackupItem: { url in
            if cleanupFails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify())
        }
        let beforeRetry = try Data(contentsOf: harness.userConfigURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: harness.userConfigURL.path
        )
        cleanupFails = false

        _ = try harness.adapter.apply()
        XCTAssertFalse(try harness.adapter.verify().connected)
        try harness.adapter.rollback()

        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), beforeRetry)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
    func testOneAdapterCannotDeleteAnotherAdaptersBackupGeneration() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try harness.writeUserConfig(
            #"{"mcpServers":{"user-edit":{"command":"true"}}}"#,
            permissions: 0o640
        )
        let second = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.helperURL,
            brokerSocketPath: harness.socketPath,
            signing: .development
        )
        _ = try second.apply()

        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify()) { error in
                XCTAssertEqual(error as? CursorMCPError, .backupCleanupFailed)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
            XCTAssertTrue(try second.verify().connected)
        }
    }
    func testRollbackRestoresOriginalBytesAndPermissions() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o640)
        _ = try harness.adapter.apply()
        XCTAssertNotEqual(try Data(contentsOf: harness.userConfigURL), original)
        try harness.adapter.rollback()
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), original)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
    func testRollbackPreservesAnExistingEmptyConfigFile() throws {
        let harness = try makeHarness()
        try harness.writeUserConfig(Data(), permissions: 0o640)

        _ = try harness.adapter.apply()
        try harness.adapter.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), Data())
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
    func testRollbackRemovesConfigOnlyWhenItDidNotExistBeforeApply() throws {
        let harness = try makeHarness()

        _ = try harness.adapter.apply()
        try harness.adapter.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }
    func testExternalDeleteAfterApplyIsNotRecreatedByRollback() throws {
        let harness = try makeHarness()
        try harness.writeUserConfig("{}", permissions: 0o640)
        _ = try harness.adapter.apply()
        try FileManager.default.removeItem(at: harness.userConfigURL)
        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }
    func testRollbackRemovalFailureIsVisibleAndKeepsTheBackup() throws {
        let harness = try makeHarness(removeConfig: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        _ = try harness.adapter.apply()

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }
    func testRollbackRefusesToDeleteAConfigCreatedConcurrently() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        let concurrent = Data(#"{"mcpServers":{"other":{"command":"true"}}}"#.utf8)
        try concurrent.write(to: harness.userConfigURL, options: .atomic)

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }
    func testRollbackRefusesToDeleteAnEmptyConfigCreatedConcurrently() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try Data().write(to: harness.userConfigURL, options: .atomic)

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), Data())
    }
    func testRollbackDoesNotDeleteAReplacementRacingWithRemoval() throws {
        let concurrent = Data(#"{"mcpServers":{"racing":{"command":"true"}}}"#.utf8)
        var raceDuringRollback = false
        let harness = try makeHarness(moveConfigExclusively: { source, destination in
            if raceDuringRollback {
                try concurrent.write(to: source, options: .atomic)
            }
            let result = destination.path.withCString { destinationPath in
                source.path.withCString { sourcePath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw CursorMCPError.rollbackFailed }
        })
        _ = try harness.adapter.apply()
        raceDuringRollback = true

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }
    func testRollbackDoesNotOverwriteAReplacementRacingWithRestore() throws {
        let concurrent = Data(#"{"mcpServers":{"racing":{"command":"true"}}}"#.utf8)
        var moveCount = 0
        let harness = try makeHarness(moveConfigExclusively: { source, destination in
            moveCount += 1
            if moveCount == 2 {
                try concurrent.write(to: destination, options: .atomic)
            }
            let result = destination.path.withCString { destinationPath in
                source.path.withCString { sourcePath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw CursorMCPError.rollbackFailed }
        })
        let original = Data(#"{"mcpServers":{"original":{"command":"true"}}}"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o640)
        _ = try harness.adapter.apply()
        moveCount = 0

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }
    func testRepeatedApplyKeepsThePreAskKeyBackup() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o644)
        _ = try harness.adapter.apply()
        _ = try harness.adapter.apply()
        try harness.adapter.rollback()
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), original)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o644)
    }
}
