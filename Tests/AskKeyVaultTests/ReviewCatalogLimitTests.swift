import Foundation
import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ReviewCatalogLimitTests: XCTestCase {
    private func makeVault() throws -> (vault: Vault, store: VaultStore, directory: URL, key: SymmetricKey) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKey-field-limits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        let key = VaultCrypto.generateKey()
        return (Vault(store: store, key: key, fileDeliveryManager: try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries"))), store, directory, key)
    }

    func testCredentialNameRejects255CharactersAboveTheUTF8Limit() throws {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 255)
        XCTAssertEqual(name.count, CredentialName.maximumLength)
        XCTAssertGreaterThan(name.utf8.count, BrokerLimits.maximumFieldBytes)

        XCTAssertThrowsError(try CredentialName.displayName(from: name)) { error in
            guard case VaultError.invalidCredentialName = error else {
                return XCTFail("expected invalidCredentialName, got \(error)")
            }
        }
    }

    func testTextCreateAndUpdateRejectOversizedFieldsWithoutChangingTheStoredRecord() throws {
        let fixture = try makeVault()
        let vault = fixture.vault
        try vault.beginManagementSession(using: .allow)
        let valid = String(repeating: "_", count: BrokerLimits.maximumFieldBytes)
        let created = try vault.createTextCredential(
            .init(name: "TOKEN", value: "value", usageInstructions: valid, environmentVariable: valid),
            using: .allow
        )

        let tooLong = String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
        XCTAssertThrowsError(try vault.createTextCredential(
            .init(name: "BAD_USAGE", value: "value", usageInstructions: tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .usageInstructionsTooLong)
        }
        XCTAssertThrowsError(try vault.createTextCredential(
            .init(name: "BAD_MAPPING", value: "value", environmentVariable: "A" + tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .environmentVariableTooLong)
        }
        XCTAssertThrowsError(try vault.updateTextCredential(
            id: created.id,
            .init(name: "TOKEN", value: "changed", usageInstructions: tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .usageInstructionsTooLong)
        }

        let stored = try XCTUnwrap(try vault.listTextCredentials().first)
        XCTAssertEqual(stored.id, created.id)
        XCTAssertEqual(stored.value, nil)
        XCTAssertEqual(stored.usageInstructions, valid)
        XCTAssertEqual(stored.environmentVariable, valid)
        XCTAssertEqual(try fixture.store.fetchAllCredentials().count, 1)
    }

    func testFileAndBundleWritesUseTheSameFieldLimit() throws {
        let fixture = try makeVault()
        let vault = fixture.vault
        try vault.beginManagementSession(using: .allow)
        let file = try FileImport.FrozenFile(originalFilename: "fixture.txt", bytes: Data("v".utf8))
        let tooLong = String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)

        XCTAssertThrowsError(try vault.createFileCredential(
            .init(name: "FILE_USAGE", snapshot: file, usageInstructions: tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .usageInstructionsTooLong)
        }
        XCTAssertThrowsError(try vault.createFileCredential(
            .init(name: "FILE_MAPPING", snapshot: file, environmentVariable: "A" + tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .environmentVariableTooLong)
        }
        let component = CredentialComponentInput(
            name: "TOKEN",
            value: .text("value"),
            delivery: .environmentVariable("TOKEN")
        )
        XCTAssertThrowsError(try vault.createBundleCredential(
            .init(name: "BUNDLE_USAGE", components: [component], usageInstructions: tooLong),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .usageInstructionsTooLong)
        }
        let oversizedMapping = CredentialComponentInput(
            name: "TOKEN",
            value: .text("value"),
            delivery: .environmentVariable("A" + tooLong)
        )
        XCTAssertThrowsError(try vault.createBundleCredential(
            .init(name: "BUNDLE_MAPPING", components: [oversizedMapping]),
            using: .allow
        )) { error in
            XCTAssertEqual(error as? CredentialFieldValidationError, .environmentVariableTooLong)
        }
        XCTAssertEqual(try fixture.store.fetchAllCredentials().count, 0)
    }

    func testRejectedMetadataUpdateLeavesTheRealSocketCatalogUsable() throws {
        let fixture = try makeVault()
        try fixture.vault.beginManagementSession(using: .allow)
        let boundary = String(repeating: "_", count: BrokerLimits.maximumFieldBytes)
        let saved = try fixture.vault.createTextCredential(.init(name: "Usable", value: "synthetic",
            usageInstructions: boundary, environmentVariable: boundary), using: .allow)
        XCTAssertThrowsError(try fixture.vault.updateCredentialMetadata(id: saved.id, name: "Usable",
            usageInstructions: boundary + "x", groupName: nil, permission: .ask, expiresAt: nil, using: .allow))
        _ = try fixture.vault.createFileCredential(.init(name: "File", snapshot: try FileImport.FrozenFile(
            originalFilename: "synthetic.pem", bytes: Data("synthetic".utf8)), environmentVariable: boundary), using: .allow)
        let socketPath = "/tmp/ak-limit-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { try fixture.vault.brokerCredentialCatalog(cancellation: $0) }, requestStatus: { _, _ in nil }))
        try server.start()
        defer { server.stop() }
        let response = try BrokerSocketClient(socketPath: socketPath).send(.init(version: BrokerProtocolVersion.current, method: "catalog"))
        guard case .success(.catalog(let catalog, _)) = response else { return XCTFail("Expected a usable catalog") }
        XCTAssertEqual(catalog.count, 2)
        let text = try XCTUnwrap(catalog.first { $0.name == "Usable" })
        XCTAssertEqual(text.usageInstructions, boundary)
        XCTAssertEqual(text.environmentVariable, boundary)
        XCTAssertEqual(text.components?.first?.name, "VALUE")
        XCTAssertEqual(text.components?.first?.delivery, .environmentVariable(boundary))
        let file = try XCTUnwrap(catalog.first { $0.name == "File" })
        XCTAssertEqual(file.components?.first?.name, "FILE")
        XCTAssertEqual(file.components?.first?.delivery, .temporaryFile(boundary))
    }

    func testRealBrokerSocketFailsClosedForAnOversizedLegacyCatalogField() throws {
        let fixture = try makeVault()
        let vault = fixture.vault
        try vault.beginManagementSession(using: .allow)
        let credential = try vault.createTextCredential(.init(name: "TOKEN", value: "value"), using: .allow)
        var record = try XCTUnwrap(try fixture.store.fetchCredential(id: credential.id))
        record.encryptedUsageInstructions = try VaultCrypto.encrypt(
            String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1),
            using: fixture.key
        )
        try fixture.store.updateCredential(record)
        vault.endManagementSession()

        let socketPath = "/tmp/askkey-limit-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { try vault.brokerCredentialCatalog(cancellation: $0) },
                requestStatus: { _, _ in nil }
            )
        )
        try server.start()
        defer { server.stop() }

        let response = try BrokerSocketClient(socketPath: socketPath)
            .send(.init(version: BrokerProtocolVersion.current, method: "catalog"))
        XCTAssertEqual(response, .failure(.internalError))
    }
}
