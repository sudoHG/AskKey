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
        let (_, export) = try populatedExport()
        let document = try BackupFileForge.document(of: export)
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
        XCTAssertTrue(alpha["deletedAt"] is NSNull)
        let alphaComponent = try XCTUnwrap((alpha["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(alphaComponent["value"] as? [String: String], ["type": "text", "text": "synthetic-alpha-value"])
        XCTAssertEqual(alphaComponent["delivery"] as? [String: String], ["type": "environmentVariable", "name": "ALPHA_TOKEN"])

        let deployKey = try credential("Synthetic Deploy Key")
        XCTAssertEqual(deployKey["payloadKind"] as? String, "file")
        let file = try XCTUnwrap((deployKey["components"] as? [[String: Any]])?.first)
        XCTAssertEqual(file["value"] as? [String: String], [
            "type": "file", "filename": "synthetic_deploy_key",
            "bytes": SyntheticBackupLibrary.fileBytes.base64EncodedString(),
        ])
        XCTAssertEqual(file["delivery"] as? [String: String], ["type": "temporaryFile", "name": "DEPLOY_KEY_FILE"])

        let database = try credential("Synthetic Database")
        XCTAssertEqual(database["payloadKind"] as? String, "bundle")
        let components = try XCTUnwrap(database["components"] as? [[String: Any]])
        XCTAssertEqual(components.map { $0["name"] as? String }, ["USER", "PASSWORD", "CA", "NOTE"])
        XCTAssertEqual(components.map { $0["masked"] as? Bool }, [false, true, true, true])
        XCTAssertEqual(components[2]["delivery"] as? [String: String], ["type": "temporaryFile", "name": "DB_CA_FILE"])
        XCTAssertEqual(components[3]["delivery"] as? [String: String], ["type": "none"])

        XCTAssertEqual(try credential("Synthetic Hidden Token")["permission"] as? String, "hidden")
        XCTAssertEqual(try credential("Synthetic Expired Token")["expiresAt"] as? String, "2023-11-14T22:13:20Z")
        let recycled = try credential("Synthetic Recycled Token")
        XCTAssertNotNil(recycled["deletedAt"] as? String)
        XCTAssertEqual(recycled["group"] as? String, "Synthetic Archive")
        for credential in credentials {
            XCTAssertNotNil(credential["createdAt"] as? String)
            XCTAssertNotNil(credential["updatedAt"] as? String)
        }
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
        XCTAssertEqual(prompts.reasons, [CredentialManagementCopy.revealReason])
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

    func testRecoveryKeyIsShownInGroupsAndReadInAnyCaseWithLookAlikes() throws {
        let (library, export) = try populatedExport()
        let text = export.recoveryKey.groupedText
        XCTAssertNotNil(text.range(of: #"\A[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){6}\z"#,
                                   options: .regularExpression), text)
        XCTAssertFalse("\(export.recoveryKey)".contains(text.prefix(4)))
        XCTAssertFalse(String(reflecting: export.recoveryKey).contains(text.prefix(4)))
        var dumped = ""
        dump(export, to: &dumped)
        XCTAssertFalse(dumped.contains(text.prefix(4)), dumped)

        let retyped = " " + text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "l") + "\n"
        let summary = try library.vault.inspectBackup(export.fileBytes, recoveryKey: retyped)
        XCTAssertEqual(summary.groupCount, SyntheticBackupLibrary.groupCount)
        let unseparated = text.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "1", with: "I")
        XCTAssertEqual(try library.vault.inspectBackup(export.fileBytes, recoveryKey: unseparated).groupCount,
                       SyntheticBackupLibrary.groupCount)
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
