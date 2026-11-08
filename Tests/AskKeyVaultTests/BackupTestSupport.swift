import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

/// A synthetic library with every kind of credential a backup must carry.
enum SyntheticBackupLibrary {
    static let credentialCount = 5
    static let recycledCount = 1
    static let groupCount = 3
    static let fileBytes = Data("synthetic-deploy-key-bytes".utf8)
    static let certificateBytes = Data("synthetic-certificate-bytes".utf8)
    static let expiry = Date(timeIntervalSince1970: 1_700_000_000)
    /// With a `BackupTestClock`, every credential is created at `createdAt`
    /// and the recycled one is deleted at `recycledAt`.
    static let createdAt = Date(timeIntervalSince1970: 1_767_323_045) // 2026-01-02T03:04:05Z
    // Within the five-minute management session, which the test clock does not renew.
    static let recycledAt = createdAt.addingTimeInterval(60)

    /// Names and values that must never appear in a backup file's bytes.
    static let plaintextMarkers = [
        "Synthetic Alpha Token", "synthetic-alpha-value", "ALPHA_TOKEN", "synthetic-alpha-usage",
        "synthetic-alpha-notes", "Synthetic Ops", "Synthetic Deploy Key", "synthetic_deploy_key",
        "DEPLOY_KEY_FILE", "Synthetic Database", "synthetic-db-user", "synthetic-db-password", "DB_PASSWORD",
        "synthetic-ca.pem", "Synthetic Hidden Token", "synthetic-hidden-value", "Synthetic Expired Token",
        "synthetic-expired-value", "Synthetic Recycled Token", "synthetic-recycled-value", "Synthetic Archive",
        "Synthetic Empty Group",
    ]

    /// Text, file, multi-component, Hidden, expired and recycled credentials
    /// and an empty group, created through the normal Vault operations.
    /// Leaves an active management session.
    static func populate(_ vault: Vault, clock: BackupTestClock? = nil) throws {
        clock?.now = createdAt
        _ = try vault.createTextCredential(.init(
            name: "Synthetic Alpha Token", value: "synthetic-alpha-value",
            usageInstructions: "synthetic-alpha-usage", privateNotes: "synthetic-alpha-notes",
            groupName: "Synthetic Ops", environmentVariable: "ALPHA_TOKEN", permission: .allowed
        ), using: .allow)
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createFileCredential(.init(
            name: "Synthetic Deploy Key",
            snapshot: try FileImport.FrozenFile(originalFilename: "synthetic_deploy_key", bytes: fileBytes),
            environmentVariable: "DEPLOY_KEY_FILE"
        ), using: .allow)
        _ = try vault.createBundleCredential(.init(name: "Synthetic Database", components: [
            .init(name: "USER", value: .text("synthetic-db-user"), delivery: .environmentVariable("DB_USER"), masked: false),
            .init(name: "PASSWORD", value: .text("synthetic-db-password"), delivery: .environmentVariable("DB_PASSWORD")),
            .init(name: "CA", value: .file(filename: "synthetic-ca.pem", bytes: certificateBytes),
                  delivery: .temporaryFile("DB_CA_FILE")),
            .init(name: "NOTE", value: .text("synthetic-db-note"), delivery: .none),
        ], groupName: "Synthetic Ops"), using: .allow)
        _ = try vault.createTextCredential(.init(
            name: "Synthetic Hidden Token", value: "synthetic-hidden-value", permission: .hidden
        ), using: .allow)
        _ = try vault.createTextCredential(.init(
            name: "Synthetic Expired Token", value: "synthetic-expired-value",
            environmentVariable: "EXPIRED_TOKEN", expiresAt: expiry
        ), using: .allow)
        let recycled = try vault.createTextCredential(.init(
            name: "Synthetic Recycled Token", value: "synthetic-recycled-value", groupName: "Synthetic Archive"
        ), using: .allow)
        clock?.now = recycledAt
        try vault.deleteTextCredential(id: recycled.id, using: .allow)
        try vault.createCredentialGroup("Synthetic Empty Group", using: .allow)
    }
}

/// A clock the test sets by hand, injected through `Vault`'s `now:`.
final class BackupTestClock {
    var now: Date

    init(_ now: Date) { self.now = now }
}

/// An independent implementation of the ADR 0012 file format, used to read
/// exported files and to build adversarial ones that only the holder of the
/// recovery key could produce. It never calls the Vault's codec.
enum BackupFileForge {
    static let magic = Data("AskKeyBackup".utf8)
    static let headerByteCount = 46
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    /// A valid recovery key that contains both `0` and `1`, computed outside
    /// Ask Key from the secret below and its CRC-12 checksum.
    static let fixedRecoveryKey = "W38E-HK2V-7PX0-Y8MQ-Z2SH-10P3-H412"
    static let fixedRecoveryKeySecret = "e0d0e8cc5b3dba0f2297f8b31082c389"

    static func secret(of recoveryKey: String) throws -> SymmetricKey {
        let symbols = recoveryKey.uppercased().filter { $0 != "-" }
        XCTAssertEqual(symbols.count, 28)
        let bits = try symbols.flatMap { symbol -> [UInt8] in
            let value = try XCTUnwrap(alphabet.firstIndex(of: symbol))
            return (0..<5).reversed().map { UInt8(value >> $0 & 1) }
        }
        return SymmetricKey(data: (0..<16).map { byte in
            bits[byte * 8..<byte * 8 + 8].reduce(UInt8(0)) { $0 << 1 | $1 }
        })
    }

    static func payloadKey(recoveryKey: String, salt: Data) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: try secret(of: recoveryKey), salt: salt,
                               info: Data("AskKey backup payload key".utf8), outputByteCount: 32)
    }

    static func document(of export: BackupExport) throws -> [String: Any] {
        let file = export.fileBytes
        let header = Data(file.prefix(headerByteCount))
        XCTAssertEqual(header.prefix(magic.count), magic)
        XCTAssertEqual([UInt8](header[12..<14]), [0, 1])
        let key = try payloadKey(recoveryKey: export.recoveryKey.groupedText, salt: Data(header.suffix(32)))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(file.dropFirst(headerByteCount))),
                                         using: key, authenticating: header)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
    }

    static func seal(_ document: [String: Any], recoveryKey: String, version: UInt16 = 1) throws -> Data {
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let header = magic + Data([UInt8(version >> 8), UInt8(version & 0xFF)]) + salt
        let plaintext = try JSONSerialization.data(withJSONObject: document)
        let sealed = try AES.GCM.seal(plaintext, using: payloadKey(recoveryKey: recoveryKey, salt: salt),
                                      authenticating: header)
        return header + (try XCTUnwrap(sealed.combined))
    }

    /// Re-seals the export's own document after `change`, with its own recovery key.
    static func rewrite(
        _ export: BackupExport, version: UInt16 = 1, _ change: (inout [String: Any]) throws -> Void = { _ in }
    ) throws -> Data {
        var document = try document(of: export)
        try change(&document)
        return try seal(document, recoveryKey: export.recoveryKey.groupedText, version: version)
    }

    static func rewriteCredentials(
        _ export: BackupExport, _ change: (inout [[String: Any]]) throws -> Void
    ) throws -> Data {
        try rewrite(export) { document in
            var credentials = try XCTUnwrap(document["credentials"] as? [[String: Any]])
            try change(&credentials)
            document["credentials"] = credentials
        }
    }

    static func index(of name: String, in credentials: [[String: Any]]) throws -> Int {
        try XCTUnwrap(credentials.firstIndex { $0["name"] as? String == name })
    }
}

func XCTAssertBackupError<T>(
    _ expression: @autoclosure () throws -> T, _ expected: BackupFileError, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), message, file: file, line: line) { error in
        XCTAssertEqual(error as? BackupFileError, expected, "\(message): \(error)", file: file, line: line)
    }
}
