import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class CredentialStorageAuthenticationTests: XCTestCase {
    func testKeylessPermissionRewriteDoesNotBypassApproval() throws {
        let harness = try makeVault()
        defer { try? harness.store.close() }
        let created = try harness.vault.createTextCredential(
            .init(name: "ASK", value: "synthetic-ask-value", environmentVariable: "TOKEN", permission: .ask),
            using: .allow
        )
        guard case .approvalRequired = try resolve(harness.vault, name: "ASK") else {
            return XCTFail("Fixture must require approval before tampering")
        }
        let before = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        try harness.store.db.write { db in
            try db.execute(sql: "UPDATE credentials SET permission = 'allowed' WHERE id = ?", arguments: [created.id])
        }
        let rawAfter = try harness.store.db.read { try CredentialRecord.fetchOne($0, key: created.id) }
        XCTAssertEqual(before.encryptedPayload, rawAfter?.encryptedPayload)
        XCTAssertEqual(before.authenticationTag, rawAfter?.authenticationTag)
        XCTAssertThrowsError(try resolve(harness.vault, name: "ASK"))
        XCTAssertThrowsError(try harness.store.fetchAllCredentials(cancellation: .init()))
    }

    func testHiddenCiphertextCannotBeRelocatedIntoAllowedCredential() throws {
        let harness = try makeVault()
        defer { try? harness.store.close() }
        let hidden = try harness.vault.createTextCredential(
            .init(name: "HIDDEN", value: "synthetic-hidden-value", environmentVariable: "HIDDEN_TOKEN", permission: .hidden),
            using: .allow
        )
        let allowed = try harness.vault.createTextCredential(
            .init(name: "ALLOWED", value: "synthetic-allowed-value", environmentVariable: "TOKEN", permission: .allowed),
            using: .allow
        )
        XCTAssertEqual(try resolvedValue(harness.vault, name: "ALLOWED"), "synthetic-allowed-value")
        try harness.store.db.write { db in
            try db.execute(sql: """
                UPDATE credentials
                SET encrypted_payload = (SELECT encrypted_payload FROM credentials WHERE id = ?)
                WHERE id = ?
                """, arguments: [hidden.id, allowed.id])
        }
        XCTAssertThrowsError(try resolve(harness.vault, name: "ALLOWED"))
    }

    func testExpiryRewriteAndAuthenticationRemovalFailClosed() throws {
        for sql in ["UPDATE credentials SET expires_at = NULL", "UPDATE credentials SET authentication_tag = NULL"] {
            let harness = try makeVault()
            defer { try? harness.store.close() }
            _ = try harness.vault.createTextCredential(
                .init(
                    name: "EXPIRED", value: "synthetic-expired", environmentVariable: "TOKEN",
                    permission: .allowed, expiresAt: Date(timeIntervalSince1970: 1)
                ),
                using: .allow
            )
            XCTAssertThrowsError(try resolve(harness.vault, name: "EXPIRED"))
            try harness.store.db.write { try $0.execute(sql: sql) }
            XCTAssertThrowsError(try resolve(harness.vault, name: "EXPIRED"))
        }
    }

    func testNormalUpdateRecycleRestoreAndReopenRemainAuthenticated() throws {
        let harness = try makeVault()
        let created = try harness.vault.createTextCredential(
            .init(name: "EDIT", value: "synthetic-before", environmentVariable: "TOKEN", permission: .allowed),
            using: .allow
        )
        _ = try harness.vault.updateTextCredential(
            id: created.id,
            .init(name: "EDIT", value: "synthetic-after", environmentVariable: "TOKEN", permission: .allowed),
            using: .allow
        )
        XCTAssertEqual(try resolvedValue(harness.vault, name: "EDIT"), "synthetic-after")
        try harness.vault.deleteTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(try harness.vault.listRecycledTextCredentials().count, 1)
        try harness.vault.restoreRecycledTextCredential(id: created.id, using: .allow)
        try harness.store.close()

        let reopened = try VaultStore(path: harness.path.path)
        defer { try? reopened.close() }
        reopened.bindCredentialAuthenticationKey(testKey)
        XCTAssertEqual(try reopened.fetchAllCredentials().map(\.id), [created.id])
        XCTAssertEqual(try reopened.fetchRecycledCredentials().count, 0)
    }

    private var testKey: SymmetricKey { SymmetricKey(data: Data(repeating: 0x62, count: 32)) }

    private func resolve(_ vault: Vault, name: String) throws -> BrokerTextCredentialResolution {
        // Calls only the resolver. No BrokerTextRuntime or target process runs.
        try vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: [name]), cancellation: .init()
        )
    }

    private func resolvedValue(_ vault: Vault, name: String) throws -> String? {
        let result = try resolve(vault, name: name)
        guard case .resolved(let values, _, let lease) = result else {
            XCTFail("Fixture should resolve an allowed credential")
            return nil
        }
        defer { lease?.finish() }
        return values.first?.value
    }

    private func makeVault() throws -> (vault: Vault, store: VaultStore, path: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyStorageAuth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("audit.sqlite")
        let store = try VaultStore(path: path.path)
        let vault = Vault(
            store: store, key: testKey,
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in false }),
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        )
        try vault.beginManagementSession(using: .allow)
        return (vault, store, path)
    }
}
