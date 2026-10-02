import XCTest
import CryptoKit
@testable import AskKeyCore

final class VaultCryptoTests: XCTestCase {
    func testEncryptDecryptRoundtrip() throws {
        let key = VaultCrypto.generateKey()
        let original = "sk-test-1234567890"
        let encrypted = try VaultCrypto.encrypt(original, using: key)
        let decrypted = try VaultCrypto.decrypt(encrypted, using: key)
        XCTAssertEqual(original, decrypted)
    }

    func testEncryptProducesUniqueNonces() throws {
        let key = VaultCrypto.generateKey()
        let value = "same-value"
        let a = try VaultCrypto.encrypt(value, using: key)
        let b = try VaultCrypto.encrypt(value, using: key)
        XCTAssertNotEqual(a, b, "Each encryption should use a unique nonce")
    }

    func testDecryptWithWrongKeyFails() throws {
        let key1 = VaultCrypto.generateKey()
        let key2 = VaultCrypto.generateKey()
        let encrypted = try VaultCrypto.encrypt("secret", using: key1)
        XCTAssertThrowsError(try VaultCrypto.decrypt(encrypted, using: key2))
    }

    func testKeyRoundtrip() {
        let key = VaultCrypto.generateKey()
        let data = VaultCrypto.keyToData(key)
        let restored = VaultCrypto.keyFromData(data)
        XCTAssertEqual(VaultCrypto.keyToData(restored), data)
    }
}

final class EnvFileFormatTests: XCTestCase {
    func testFormatsPlainValue() {
        XCTAssertEqual(EnvFileFormat.line(name: "API_KEY", value: "abc123"), "API_KEY=\"abc123\"")
    }

    func testEscapesBackslashesAndQuotes() {
        XCTAssertEqual(
            EnvFileFormat.line(name: "TRICKY", value: #"a\b"c"#),
            #"TRICKY="a\\b\"c""#
        )
    }

    func testParsesBareAndQuotedAndExportLines() {
        let content = """
        # comment
        FOO=bar
        export TOKEN="sk-123"
        QUOTED='single'

        WITH_COMMENT=value # trailing
        """
        let pairs = EnvFileFormat.parse(content)
        XCTAssertEqual(pairs.map(\.name), ["FOO", "TOKEN", "QUOTED", "WITH_COMMENT"])
        XCTAssertEqual(pairs.map(\.value), ["bar", "sk-123", "single", "value"])
    }

    func testSkipsBlankAndCommentAndKeylessLines() {
        let pairs = EnvFileFormat.parse("\n#only a comment\n=novalue\nKEY=ok\n")
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.name, "KEY")
        XCTAssertEqual(pairs.first?.value, "ok")
    }
}

final class CurrentSchemaTests: XCTestCase {
    func testCurrentSchemaRemovesEveryFolderAssociationColumnAndTable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCurrentSchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)

        let result = try store.db.read { database in
            (
                try database.columns(in: "projects").map(\.name),
                try database.tableExists("folder_associations")
            )
        }

        XCTAssertFalse(result.0.contains("path"))
        XCTAssertFalse(result.1)
    }

    func testNewStoreStillCreatesLegacyProjectAndSecretTables() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyLegacySchema-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)

        let result = try store.db.read { database in
            (
                try database.tableExists("projects"),
                try database.tableExists("environments"),
                try database.tableExists("secrets"),
                try database.tableExists("secret_values"),
                try database.columns(in: "projects").map(\.name)
            )
        }

        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
        XCTAssertTrue(result.2)
        XCTAssertTrue(result.3)
        XCTAssertFalse(result.4.contains("path"))
    }
}

final class VaultConfigurationTests: XCTestCase {
    func testDebugBuildUsesDevelopmentStorage() {
        #if DEBUG
        XCTAssertTrue(VaultConfiguration.isDevelopmentBuild)
        if let root = VaultConfiguration.debugRunDirectory {
            XCTAssertTrue(VaultConfiguration.keychainService.hasPrefix("com.sudohg.askkey.vault.dev.run."))
            XCTAssertEqual(VaultConfiguration.vaultFileURL.path, root.appendingPathComponent("core/vault.db").path)
        } else {
            XCTAssertEqual(VaultConfiguration.keychainService, "com.sudohg.askkey.vault.dev")
            XCTAssertTrue(VaultConfiguration.vaultFileURL.path.hasSuffix("/AskKey/dev/vault.db"))
        }
        #else
        XCTAssertFalse(VaultConfiguration.isDevelopmentBuild)
        XCTAssertEqual(VaultConfiguration.keychainService, "com.sudohg.askkey.vault")
        XCTAssertTrue(VaultConfiguration.vaultFileURL.path.hasSuffix("/AskKey/vault.db"))
        #endif
    }
}
