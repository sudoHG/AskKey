import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

/// Audit counterexamples: safe expectations intentionally fail on the reviewed HEAD.
/// Uses only synthetic bytes, an isolated temporary database, injected keys/authentication,
/// and uniquely owned local directories. No App, Keychain, real cloud or process spawn.
final class AuditStorageBoundaryTests: XCTestCase {


    func testBrokerDoesNotDeliverAfterKeylessSQLPromotesAskPermission() throws {
        let harness = try makeVault()
        defer { try? harness.store.close() }
        let credential = try harness.vault.createTextCredential(
            .init(
                name: "AUDIT_ASK",
                value: "SYNTHETIC_ASK_VALUE",
                environmentVariable: "AUDIT_TOKEN",
                permission: .ask
            ),
            using: .allow
        )
        let before = try XCTUnwrap(harness.store.fetchCredential(id: credential.id))
        let baseline = try harness.vault.brokerTextCredentials(
            for: request(name: "AUDIT_ASK"), cancellation: .init()
        )
        guard case .approvalRequired = baseline else {
            finishIfResolved(baseline)
            return XCTFail("Fixture must require approval before tampering")
        }

        // Attacker step: SQL has no key and leaves every ciphertext untouched.
        try harness.store.db.write { database in
            try database.execute(
                sql: "UPDATE credentials SET permission = ? WHERE id = ?",
                arguments: [CredentialPermission.allowed.rawValue, credential.id]
            )
        }
        // Inspect raw ciphertext without passing through the now-authenticated store read.
        let after = try harness.store.db.read { database in
            try XCTUnwrap(CredentialRecord.fetchOne(database, key: credential.id))
        }
        XCTAssertEqual(before.encryptedPayload, after.encryptedPayload)
        XCTAssertEqual(before.encryptedDisplayName, after.encryptedDisplayName)
        XCTAssertEqual(before.encryptedEnvironmentVariable, after.encryptedEnvironmentVariable)
        XCTAssertThrowsError(try harness.store.fetchCredential(id: credential.id))

        assertNoUnapprovedDelivery(vault: harness.vault, name: "AUDIT_ASK")
    }

    func testBrokerRejectsHiddenCiphertextRelocatedIntoAllowedCredential() throws {
        let harness = try makeVault()
        defer { try? harness.store.close() }
        let hidden = try harness.vault.createTextCredential(
            .init(
                name: "AUDIT_HIDDEN",
                value: "SYNTHETIC_HIDDEN_VALUE",
                environmentVariable: "AUDIT_HIDDEN_TOKEN",
                permission: .hidden
            ),
            using: .allow
        )
        let allowed = try harness.vault.createTextCredential(
            .init(
                name: "AUDIT_ALLOWED",
                value: "SYNTHETIC_ALLOWED_VALUE",
                environmentVariable: "AUDIT_ALLOWED_TOKEN",
                permission: .allowed
            ),
            using: .allow
        )
        let baseline = try harness.vault.brokerTextCredentials(
            for: request(name: "AUDIT_ALLOWED"), cancellation: .init()
        )
        guard case .resolved(let credentials, _, let lease) = baseline else {
            return XCTFail("Fixture must deliver the original allowed credential")
        }
        lease?.finish()
        XCTAssertEqual(credentials.first?.value, "SYNTHETIC_ALLOWED_VALUE")

        // Both rows have the same kind. This subquery relocates only ciphertext;
        // it does not decrypt it, know the key, change permissions or authorize a read.
        try harness.store.db.write { database in
            try database.execute(
                sql: """
                    UPDATE credentials
                    SET encrypted_payload = (SELECT encrypted_payload FROM credentials WHERE id = ?)
                    WHERE id = ?
                    """,
                arguments: [hidden.id, allowed.id]
            )
        }
        assertNoUnapprovedDelivery(vault: harness.vault, name: "AUDIT_ALLOWED")
    }

    private func assertNoUnapprovedDelivery(
        vault: Vault,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let result = try vault.brokerTextCredentials(for: request(name: name), cancellation: .init())
            switch result {
            case .approvalRequired:
                // Requiring a fresh decision also preserves the no-disclosure boundary.
                break
            case .resolved(_, _, let lease):
                lease?.finish()
                XCTFail("Keyless database tampering must not yield credential material", file: file, line: line)
            }
        } catch {
            // An integrity/refusal error is the intended fail-closed result.
        }
    }

    private func finishIfResolved(_ result: BrokerTextCredentialResolution) {
        if case .resolved(_, _, let lease) = result { lease?.finish() }
    }

    private func request(name: String) -> BrokerTextRunRequest {
        // Only calls the in-process resolver; this command is never executed.
        .init(command: ["/usr/bin/true"], credentialNames: [name])
    }

    private func makeVault() throws -> (vault: Vault, store: VaultStore) {
        let root = try makeRoot()
        let store = try VaultStore(path: root.appendingPathComponent("audit.sqlite").path)
        let manager = try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        let vault = Vault(
            store: store,
            key: SymmetricKey(data: Data(repeating: 0x62, count: 32)),
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in false }),
            fileDeliveryManager: manager
        )
        try vault.beginManagementSession(using: .allow)
        return (vault, store)
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AskKeyAuditStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

}
