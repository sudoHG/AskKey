import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import AskKeyVault

final class BackupExportTests: XCTestCase {
    private var libraries: [AgentAccessPolicyLibrary] = []

    override func tearDownWithError() throws {
        for library in libraries { try library.close() }
        libraries = []
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        libraries.append(library)
        return library
    }

    private func populatedExport() throws -> (AgentAccessPolicyLibrary, BackupExport) {
        let library = try makeLibrary()
        try SyntheticBackupLibrary.populate(library.vault)
        return (library, try library.vault.exportBackup(using: .allow))
    }

    func testExportThenInspectCountsEveryKindOfCredentialAndGroup() throws {
        let before = Date(timeIntervalSinceNow: -1)
        let (source, export) = try populatedExport()
        let target = try makeLibrary()

        // The source inspects with its session; the empty target, which has a
        // different App key, inspects under the first-run allowance.
        for vault in [source.vault, target.vault] {
            let summary = try vault.inspectBackup(export.fileBytes, recoveryKey: export.recoveryKey.groupedText)
            XCTAssertEqual(summary.credentialCount, SyntheticBackupLibrary.credentialCount)
            XCTAssertEqual(summary.recycledCount, SyntheticBackupLibrary.recycledCount)
            XCTAssertEqual(summary.groupCount, SyntheticBackupLibrary.groupCount)
            XCTAssertGreaterThanOrEqual(summary.createdAt, before.addingTimeInterval(-1))
            XCTAssertLessThanOrEqual(summary.createdAt, Date())
        }
        XCTAssertNotEqual(try source.key.withUnsafeBytes { Data($0) }, try target.key.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try target.vault.storedCredentialCount(), 0)
    }

    func testExportCarriesEveryFieldIncludingHiddenAndRecycledCredentials() throws {
        let clock = BackupTestClock(SyntheticBackupLibrary.createdAt)
        let library = try AgentAccessPolicyLibrary(now: { clock.now })
        libraries.append(library)
        try SyntheticBackupLibrary.populate(library.vault, clock: clock)
        clock.now = SyntheticBackupLibrary.createdAt.addingTimeInterval(120)
        let hidden = try XCTUnwrap(try library.vault.listTextCredentials().first { $0.name == "Synthetic Hidden Token" })
        try library.vault.updateCredentialPermission(id: hidden.id, permission: .hidden, using: .allow)
        clock.now = SyntheticBackupLibrary.createdAt.addingTimeInterval(180)
        let export = try library.vault.exportBackup(using: .allow)

        XCTAssertEqual(try library.vault.inspectBackup(export.fileBytes, recoveryKey: export.recoveryKey.groupedText)
                        .createdAt, clock.now)
        let document = try BackupFileForge.document(of: export)
        XCTAssertEqual(document["createdAt"] as? String, "2026-01-02T03:07:05Z")
        XCTAssertEqual(document["groups"] as? [String],
                       ["Synthetic Archive", "Synthetic Empty Group", "Synthetic Ops"])
        let credentials = try XCTUnwrap(document["credentials"] as? [[String: Any]])
        func credential(_ name: String) throws -> [String: Any] {
            credentials[try BackupFileForge.index(of: name, in: credentials)]
        }

        let alpha = try credential("Synthetic Alpha Token")
        XCTAssertEqual(alpha["payloadKind"] as? String, "text")
        XCTAssertEqual(alpha["permission"] as? String, "allowed")
        XCTAssertEqual(alpha["usageInstructions"] as? String, "synthetic-alpha-usage")
        XCTAssertEqual(alpha["privateNotes"] as? String, "synthetic-alpha-notes")
        XCTAssertEqual(alpha["group"] as? String, "Synthetic Ops")
        XCTAssertEqual(alpha["createdAt"] as? String, "2026-01-02T03:04:05Z")
        XCTAssertEqual(alpha["updatedAt"] as? String, "2026-01-02T03:04:05Z")
        XCTAssertTrue(alpha["expiresAt"] is NSNull)
        XCTAssertTrue(alpha["deletedAt"] is NSNull)
        XCTAssertEqual(alpha["components"] as? NSArray, [[
            "name": "ALPHA_TOKEN", "value": ["type": "text", "text": "synthetic-alpha-value"],
            "delivery": ["type": "environmentVariable", "name": "ALPHA_TOKEN"], "masked": true,
        ]] as NSArray)

        let deployKey = try credential("Synthetic Deploy Key")
        XCTAssertEqual(deployKey["payloadKind"] as? String, "file")
        XCTAssertEqual(deployKey["components"] as? NSArray, [[
            "name": "DEPLOY_KEY_FILE",
            "value": ["type": "file", "filename": "synthetic_deploy_key",
                      "bytes": SyntheticBackupLibrary.fileBytes.base64EncodedString()],
            "delivery": ["type": "temporaryFile", "name": "DEPLOY_KEY_FILE"], "masked": true,
        ]] as NSArray)

        let database = try credential("Synthetic Database")
        XCTAssertEqual(database["payloadKind"] as? String, "bundle")
        XCTAssertEqual(database["components"] as? NSArray, [
            ["name": "USER", "value": ["type": "text", "text": "synthetic-db-user"],
             "delivery": ["type": "environmentVariable", "name": "DB_USER"], "masked": false],
            ["name": "PASSWORD", "value": ["type": "text", "text": "synthetic-db-password"],
             "delivery": ["type": "environmentVariable", "name": "DB_PASSWORD"], "masked": true],
            ["name": "CA",
             "value": ["type": "file", "filename": "synthetic-ca.pem",
                       "bytes": SyntheticBackupLibrary.certificateBytes.base64EncodedString()],
             "delivery": ["type": "temporaryFile", "name": "DB_CA_FILE"], "masked": true],
            ["name": "NOTE", "value": ["type": "text", "text": "synthetic-db-note"],
             "delivery": ["type": "none"], "masked": true],
        ] as NSArray)

        let hiddenToken = try credential("Synthetic Hidden Token")
        XCTAssertEqual(hiddenToken["permission"] as? String, "hidden")
        XCTAssertEqual(hiddenToken["createdAt"] as? String, "2026-01-02T03:04:05Z")
        XCTAssertEqual(hiddenToken["updatedAt"] as? String, "2026-01-02T03:06:05Z")
        XCTAssertEqual(try credential("Synthetic Expired Token")["expiresAt"] as? String, "2023-11-14T22:13:20Z")
        let recycled = try credential("Synthetic Recycled Token")
        XCTAssertEqual(recycled["group"] as? String, "Synthetic Archive")
        XCTAssertEqual(recycled["createdAt"] as? String, "2026-01-02T03:04:05Z")
        XCTAssertEqual(recycled["updatedAt"] as? String, "2026-01-02T03:04:05Z")
        XCTAssertEqual(recycled["deletedAt"] as? String, "2026-01-02T03:05:05Z")
    }

    func testExportWithoutManagementSessionFailsBeforeAuthentication() throws {
        let library = try makeLibrary()
        try SyntheticBackupLibrary.populate(library.vault)
        library.vault.endManagementSession()
        let prompts = BackupPromptRecorder()

        XCTAssertThrowsError(try library.vault.exportBackup(using: prompts.authenticator(result: true))) { error in
            guard case VaultError.managementAuthenticationRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(prompts.reasons, [])
    }

    func testCancelledOrFailedAuthenticationProducesNoBackup() throws {
        let library = try makeLibrary()
        try SyntheticBackupLibrary.populate(library.vault)
        let prompts = BackupPromptRecorder()
        var export: BackupExport?

        XCTAssertThrowsError(export = try library.vault.exportBackup(using: prompts.authenticator(result: false))) { error in
            guard case VaultError.managementAuthenticationRequired = error else { return XCTFail("\(error)") }
        }
        XCTAssertNil(export)
        XCTAssertEqual(prompts.reasons, [CredentialManagementCopy.exportBackupReason])
    }

    func testExportedBytesContainNoCredentialNamesOrValues() throws {
        let (_, export) = try populatedExport()
        let markers = SyntheticBackupLibrary.plaintextMarkers.map { Data($0.utf8) } + [
            SyntheticBackupLibrary.fileBytes, SyntheticBackupLibrary.certificateBytes,
            Data(SyntheticBackupLibrary.fileBytes.base64EncodedString().utf8),
            Data(SyntheticBackupLibrary.certificateBytes.base64EncodedString().utf8),
        ]
        for marker in markers {
            XCTAssertNil(export.fileBytes.range(of: marker), String(decoding: marker, as: UTF8.self))
        }
        XCTAssertNil(export.fileBytes.range(of: Data("credentials".utf8)))
    }

    func testEveryExportUsesANewRecoveryKeyAndDifferentBytes() throws {
        let (library, first) = try populatedExport()
        let second = try library.vault.exportBackup(using: .allow)

        XCTAssertNotEqual(first.recoveryKey.groupedText, second.recoveryKey.groupedText)
        XCTAssertNotEqual(first.fileBytes, second.fileBytes)
        XCTAssertNotEqual(first.fileBytes.prefix(BackupFileForge.headerByteCount),
                          second.fileBytes.prefix(BackupFileForge.headerByteCount))
        XCTAssertBackupError(try library.vault.inspectBackup(first.fileBytes, recoveryKey: second.recoveryKey.groupedText),
                             .cannotOpen)
        XCTAssertEqual(try library.vault.inspectBackup(second.fileBytes, recoveryKey: second.recoveryKey.groupedText)
                        .credentialCount, SyntheticBackupLibrary.credentialCount)
    }

    func testRecycledRecordThatFailsAuthenticationFailsTheExport() throws {
        let library = try makeLibrary()
        try SyntheticBackupLibrary.populate(library.vault)
        try library.store.db.write { db in
            try db.execute(sql: "UPDATE credentials SET permission = 'allowed' WHERE deleted_at IS NOT NULL")
        }

        XCTAssertThrowsError(try library.vault.exportBackup(using: .allow)) { error in
            XCTAssertEqual(error as? CredentialRecordAuthenticationError, .invalidAuthentication)
        }
    }

    func testRecoveryKeyIsShownInGroupsAndNeverPrinted() throws {
        let (library, export) = try populatedExport()
        let text = export.recoveryKey.groupedText
        XCTAssertNotNil(text.range(of: #"\A[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){6}\z"#,
                                   options: .regularExpression), text)
        XCTAssertFalse("\(export.recoveryKey)".contains(text.prefix(4)))
        XCTAssertFalse(String(reflecting: export.recoveryKey).contains(text.prefix(4)))
        var dumped = ""
        dump(export, to: &dumped)
        XCTAssertFalse(dumped.contains(text.prefix(4)), dumped)

        let retyped = " " + text.lowercased().replacingOccurrences(of: "-", with: " ") + "\n"
        XCTAssertEqual(try library.vault.inspectBackup(export.fileBytes, recoveryKey: retyped).groupCount,
                       SyntheticBackupLibrary.groupCount)
    }

    func testRecoveryKeyLookAlikesReadAsZeroAndOne() throws {
        let (library, export) = try populatedExport()
        let fixed = BackupFileForge.fixedRecoveryKey
        XCTAssertTrue(fixed.contains("0") && fixed.contains("1"))
        XCTAssertEqual(try BackupFileForge.secret(of: fixed).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() },
                       BackupFileForge.fixedRecoveryKeySecret)
        // The synthetic document, sealed under a key whose symbols include 0 and 1.
        let file = try BackupFileForge.seal(try BackupFileForge.document(of: export), recoveryKey: fixed)
        XCTAssertEqual(try BackupRecoveryKey(parsing: fixed).groupedText, fixed)
        XCTAssertEqual(try library.vault.inspectBackup(file, recoveryKey: fixed).credentialCount,
                       SyntheticBackupLibrary.credentialCount)

        let variants = [
            fixed.replacingOccurrences(of: "0", with: "O"),
            fixed.replacingOccurrences(of: "0", with: "o"),
            fixed.replacingOccurrences(of: "1", with: "I"),
            fixed.replacingOccurrences(of: "1", with: "L"),
            fixed.replacingOccurrences(of: "1", with: "l"),
            fixed.lowercased().replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "i")
                .replacingOccurrences(of: "-", with: ""),
        ]
        for variant in variants {
            XCTAssertNotEqual(variant, fixed)
            XCTAssertEqual(try BackupRecoveryKey(parsing: variant).groupedText, fixed, variant)
            XCTAssertEqual(try library.vault.inspectBackup(file, recoveryKey: variant).credentialCount,
                           SyntheticBackupLibrary.credentialCount, variant)
        }
    }
}

final class BackupPromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var reasons: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func authenticator(result: Bool) -> ManagementAuthenticator {
        ManagementAuthenticator { [self] reason in
            lock.lock(); recorded.append(reason); lock.unlock()
            return result
        }
    }
}
