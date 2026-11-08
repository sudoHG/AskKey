import Foundation
import XCTest
@testable import AskKeyVault

final class BackupInspectionTests: XCTestCase {
    private var libraries: [AgentAccessPolicyLibrary] = []
    private var export: BackupExport!
    /// An empty library with a different App key, as on a new Mac.
    private var target: Vault!

    override func setUpWithError() throws {
        let source = try makeLibrary()
        try SyntheticBackupLibrary.populate(source.vault)
        export = try source.vault.exportBackup(using: .allow)
        target = try makeLibrary().vault
    }

    override func tearDownWithError() throws {
        for library in libraries { try library.close() }
        libraries = []
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        libraries.append(library)
        return library
    }

    private var recoveryKey: String { export.recoveryKey.groupedText }

    private func inspect(_ file: Data, recoveryKey: String? = nil) throws -> BackupSummary {
        try target.inspectBackup(file, recoveryKey: recoveryKey ?? self.recoveryKey)
    }

    private func assertRecoveryKeyError(_ key: String, _ expected: BackupRecoveryKeyError, file: Data? = nil,
                                        line: UInt = #line) {
        XCTAssertThrowsError(try inspect(file ?? export.fileBytes, recoveryKey: key), line: line) { error in
            XCTAssertEqual(error as? BackupRecoveryKeyError, expected, "\(error)", line: line)
        }
    }

    // MARK: - Recovery key

    func testChecksumTypoIsReportedBeforeTheFileIsRead() throws {
        var symbols = Array(recoveryKey)
        symbols[0] = symbols[0] == "A" ? "B" : "A"
        let substituted = String(symbols)
        assertRecoveryKeyError(substituted, .checksumMismatch)
        assertRecoveryKeyError(substituted, .checksumMismatch, file: Data())
        assertRecoveryKeyError(substituted, .checksumMismatch, file: Data(repeating: 0xA5, count: 4096))

        var swapped = Array(recoveryKey.replacingOccurrences(of: "-", with: ""))
        let position = try XCTUnwrap(swapped.indices.dropLast().first { swapped[$0] != swapped[$0 + 1] })
        swapped.swapAt(position, position + 1)
        assertRecoveryKeyError(String(swapped), .checksumMismatch)
    }

    func testMalformedRecoveryKeyIsDistinctFromATypo() {
        assertRecoveryKeyError("", .malformed)
        assertRecoveryKeyError(String(recoveryKey.dropLast()), .malformed)
        assertRecoveryKeyError(recoveryKey + "A", .malformed)
        assertRecoveryKeyError("U" + recoveryKey.dropFirst(), .malformed)
        assertRecoveryKeyError("*" + recoveryKey.dropFirst(), .malformed)
        assertRecoveryKeyError("\u{FF21}" + recoveryKey.dropFirst(), .malformed)
    }

    func testAnotherRecoveryKeyCannotOpenTheFile() throws {
        let other = try makeLibrary()
        _ = try other.vault.createTextCredential(.init(name: "Other", value: "synthetic-other"), using: .allow)
        try other.vault.beginManagementSession(using: .allow)
        let otherKey = try other.vault.exportBackup(using: .allow).recoveryKey.groupedText

        XCTAssertBackupError(try inspect(export.fileBytes, recoveryKey: otherKey), .cannotOpen)
    }

    // MARK: - Damaged files

    func testFlippedHeaderBytesAreRefused() {
        for index in 0..<BackupFileForge.headerByteCount {
            var damaged = export.fileBytes
            damaged[index] ^= 0x01
            // Byte 12 is the high byte of the format version, read before authentication.
            XCTAssertBackupError(try inspect(damaged), index == 12 ? .newerFormatVersion(257) : .cannotOpen,
                                 "header byte \(index)")
        }
    }

    func testFlippedPayloadBytesAreRefused() {
        let header = BackupFileForge.headerByteCount
        let count = export.fileBytes.count
        for index in [header, header + 11, header + 12, (header + count) / 2, count - 17, count - 1] {
            var damaged = export.fileBytes
            damaged[index] ^= 0x80
            XCTAssertBackupError(try inspect(damaged), .cannotOpen, "payload byte \(index)")
        }
    }

    func testTruncatedFilesAreRefused() {
        let file = export.fileBytes
        for truncated in [file.dropLast(), file.prefix(file.count - 16), file.prefix(BackupFileForge.headerByteCount + 28),
                          file.prefix(BackupFileForge.headerByteCount), file.prefix(14), file.prefix(10), Data()] {
            XCTAssertBackupError(try inspect(Data(truncated)), .cannotOpen, "\(truncated.count) bytes")
        }
        XCTAssertBackupError(try inspect(file.dropLast()), .cannotOpen)
    }

    func testFileWrittenToTheDocumentedFormatOpens() throws {
        let summary = try inspect(try BackupFileForge.rewrite(export))
        XCTAssertEqual(summary.credentialCount, SyntheticBackupLibrary.credentialCount)
        XCTAssertEqual(summary.recycledCount, SyntheticBackupLibrary.recycledCount)
        XCTAssertEqual(summary.groupCount, SyntheticBackupLibrary.groupCount)
    }

    func testNewerFormatVersionAsksForAnUpdate() throws {
        XCTAssertBackupError(try inspect(try BackupFileForge.rewrite(export, version: 2)), .newerFormatVersion(2))
        XCTAssertBackupError(try inspect(try BackupFileForge.rewrite(export, version: 0)), .cannotOpen)
    }

    // MARK: - Invalid contents

    func testUnknownPayloadKindIsRefused() throws {
        let credentialKind = try BackupFileForge.rewriteCredentials(export) { credentials in
            credentials[0]["payloadKind"] = "passkey"
        }
        XCTAssertBackupError(try inspect(credentialKind), .invalidContents(.unknownPayloadKind))

        let componentKind = try BackupFileForge.rewriteCredentials(export) { credentials in
            let index = try BackupFileForge.index(of: "Synthetic Database", in: credentials)
            var components = try XCTUnwrap(credentials[index]["components"] as? [[String: Any]])
            components[0]["value"] = ["type": "secureEnclave", "reference": "synthetic"]
            credentials[index]["components"] = components
        }
        XCTAssertBackupError(try inspect(componentKind), .invalidContents(.unknownPayloadKind))
    }

    func testDuplicateNamesAreRefused() throws {
        let caseVariant = try BackupFileForge.rewriteCredentials(export) { credentials in
            let index = try BackupFileForge.index(of: "Synthetic Hidden Token", in: credentials)
            credentials[index]["name"] = "SYNTHETIC ALPHA TOKEN"
        }
        XCTAssertBackupError(try inspect(caseVariant), .invalidContents(.duplicateCredentialName))

        let recycledCopy = try BackupFileForge.rewriteCredentials(export) { credentials in
            var copy = credentials[try BackupFileForge.index(of: "Synthetic Alpha Token", in: credentials)]
            copy["deletedAt"] = "2026-01-01T00:00:00Z"
            credentials.append(copy)
        }
        XCTAssertBackupError(try inspect(recycledCopy), .invalidContents(.duplicateCredentialName))
    }

    func testOverLimitCredentialsAreRefused() throws {
        let tooManyComponents = try BackupFileForge.rewriteCredentials(export) { credentials in
            let index = try BackupFileForge.index(of: "Synthetic Database", in: credentials)
            var components = try XCTUnwrap(credentials[index]["components"] as? [[String: Any]])
            while components.count <= CredentialBundleValidator.maximumComponents {
                components.append(["name": "EXTRA_\(components.count)", "value": ["type": "text", "text": "x"],
                                   "delivery": ["type": "none"], "masked": true])
            }
            credentials[index]["components"] = components
        }
        XCTAssertBackupError(try inspect(tooManyComponents), .invalidContents(.limitExceeded))

        let tooMuchMaterial = try BackupFileForge.rewriteCredentials(export) { credentials in
            let index = try BackupFileForge.index(of: "Synthetic Alpha Token", in: credentials)
            var components = try XCTUnwrap(credentials[index]["components"] as? [[String: Any]])
            components[0]["value"] = ["type": "text",
                                      "text": String(repeating: "a", count: CredentialBundleValidator.maximumMaterialBytes + 1)]
            credentials[index]["components"] = components
        }
        XCTAssertBackupError(try inspect(tooMuchMaterial), .invalidContents(.limitExceeded))
    }

    func testInvalidCredentialPlacedLastFailsTheWholeFile() throws {
        let cases: [(String, BackupContentsIssue, ([String: Any]) throws -> [String: Any])] = [
            ("invalid mapping", .invalidCredential, { credential in
                var credential = credential
                credential["components"] = [["name": "1INVALID", "value": ["type": "text", "text": "synthetic"],
                                             "delivery": ["type": "environmentVariable", "name": "1INVALID"],
                                             "masked": true]]
                return credential
            }),
            ("control character", .invalidCredential, { credential in
                var credential = credential
                credential["name"] = "Synthetic\u{7}Last"
                return credential
            }),
            ("untrimmed name", .invalidCredential, { credential in
                var credential = credential
                credential["name"] = " Synthetic Last"
                return credential
            }),
            ("long instructions", .invalidCredential, { credential in
                var credential = credential
                credential["usageInstructions"] = String(repeating: "u", count: 4097)
                return credential
            }),
            ("unknown permission", .invalidCredential, { credential in
                var credential = credential
                credential["permission"] = "always"
                return credential
            }),
            ("non-canonical timestamp", .invalidCredential, { credential in
                var credential = credential
                credential["createdAt"] = "2026-01-01 00:00:00"
                return credential
            }),
            ("unlisted group", .invalidGroup, { credential in
                var credential = credential
                credential["group"] = "Synthetic Unlisted"
                return credential
            }),
        ]
        for (label, issue, makeInvalid) in cases {
            let file = try BackupFileForge.rewriteCredentials(export) { credentials in
                var last = credentials[try BackupFileForge.index(of: "Synthetic Alpha Token", in: credentials)]
                last["name"] = "Synthetic Last"
                credentials.append(try makeInvalid(last))
            }
            XCTAssertBackupError(try inspect(file), .invalidContents(issue), label)
        }
    }

    func testDocumentWithUnknownOrMissingKeysIsRefused() throws {
        let extraTopLevelKey = try BackupFileForge.rewrite(export) { $0["settings"] = ["language": "en"] }
        XCTAssertBackupError(try inspect(extraTopLevelKey), .invalidContents(.malformedDocument))

        let missingNotes = try BackupFileForge.rewriteCredentials(export) { $0[0]["privateNotes"] = nil }
        XCTAssertBackupError(try inspect(missingNotes), .invalidContents(.malformedDocument))

        let extraValueKey = try BackupFileForge.rewriteCredentials(export) { credentials in
            let index = try BackupFileForge.index(of: "Synthetic Database", in: credentials)
            var components = try XCTUnwrap(credentials[index]["components"] as? [[String: Any]])
            components[0]["value"] = ["type": "text", "text": "synthetic-db-user", "filename": "x"]
            credentials[index]["components"] = components
        }
        XCTAssertBackupError(try inspect(extraValueKey), .invalidContents(.malformedDocument))

        let duplicateGroup = try BackupFileForge.rewrite(export) { document in
            document["groups"] = (document["groups"] as? [String] ?? []) + ["Synthetic Ops"]
        }
        XCTAssertBackupError(try inspect(duplicateGroup), .invalidContents(.invalidGroup))
    }

    // MARK: - Access

    func testInspectionNeedsASessionOnceTheLibraryHasCredentials() throws {
        XCTAssertEqual(try inspect(export.fileBytes).credentialCount, SyntheticBackupLibrary.credentialCount)
        XCTAssertEqual(try target.storedCredentialCount(), 0)

        let active = try makeLibrary().vault
        _ = try active.createTextCredential(.init(name: "Existing", value: "synthetic-existing"), using: .allow)
        assertManagementRequired(active)
        try active.beginManagementSession(using: .allow)
        XCTAssertEqual(try active.inspectBackup(export.fileBytes, recoveryKey: recoveryKey).recycledCount,
                       SyntheticBackupLibrary.recycledCount)

        let recycledOnly = try makeLibrary().vault
        let created = try recycledOnly.createTextCredential(.init(name: "Recycled", value: "synthetic-recycled"),
                                                            using: .allow)
        try recycledOnly.beginManagementSession(using: .allow)
        try recycledOnly.deleteTextCredential(id: created.id, using: .allow)
        recycledOnly.endManagementSession()
        assertManagementRequired(recycledOnly)

        target.lock()
        XCTAssertThrowsError(try inspect(export.fileBytes)) { error in
            guard case VaultError.vaultLocked = error else { return XCTFail("\(error)") }
        }
    }

    private func assertManagementRequired(_ vault: Vault, line: UInt = #line) {
        XCTAssertThrowsError(try vault.inspectBackup(export.fileBytes, recoveryKey: recoveryKey), line: line) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("\(error)", line: line)
            }
        }
    }
}
