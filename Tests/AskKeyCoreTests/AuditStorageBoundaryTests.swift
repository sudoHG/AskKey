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
    func testRealFileBackupStoreAcceptsCoordinatorDirectoryPrefixWithTrailingSlash() throws {
        let root = try makeRoot()
        let cloud = try makeCloud(root: root)
        let prefix = "askkey-backup/audit-key/generations"
        let blob = prefix + "/audit-generation/blob"
        try cloud.create(Data("synthetic-encrypted-placeholder".utf8), at: blob)

        // Establish that the fixture exists and the adapter works without a separator.
        XCTAssertEqual(try cloud.list(prefix: prefix), [blob])
        // The production coordinator uses exactly this trailing-slash form.
        XCTAssertEqual(try cloud.list(prefix: prefix + "/"), [blob])
    }

    func testCoordinatorRoundTripsThroughRealFileAdapterInIsolatedContainer() throws {
        let root = try makeRoot()
        let cloud = try makeCloud(root: root)
        let recoveryKey = try BackupRecoveryKey(encoded: Data(repeating: 0x51, count: 32).base64EncodedString())
        let coordinator = try ICloudBackupCoordinator(
            store: cloud,
            recoveryKey: recoveryKey,
            writerID: "11111111-1111-4111-8111-111111111111",
            stateStore: AuditBackupMemoryState()
        )
        let snapshot = ICloudBackupSnapshot(
            credentials: [.init(
                id: "audit-credential",
                displayName: "Audit Credential",
                payload: .text("SYNTHETIC_AUDIT_VALUE"),
                permission: .ask
            )],
            groupNames: [],
            settings: .init(
                languageMode: "system",
                appearanceMode: "system",
                defaultTimedAllowanceMinutes: 30,
                launchAtLogin: false
            )
        )

        _ = try coordinator.backUp(snapshot: snapshot)
        XCTAssertEqual(try coordinator.restore(), snapshot)
    }

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

    private func makeCloud(root: URL) throws -> ICloudFileBackupStore {
        try ICloudFileBackupStore(
            provider: AuditLocalContainer(root: root),
            fileManager: AuditScopedFileManager(root: root)
        )
    }
}

private struct AuditLocalContainer: ICloudBackupContainerProviding {
    let root: URL
    func containerURL() -> URL? { root }
}

private final class AuditScopedFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
}

private final class AuditBackupMemoryState: ICloudBackupLocalStateStore {
    private let lock = NSLock()
    private var paused = false
    private var takeover: String?
    private var cleanup: [String] = []
    private var uploads: [String: Data] = [:]
    func beginExclusiveAccess(namespace: String) { lock.lock() }
    func endExclusiveAccess(namespace: String) { lock.unlock() }
    func isAutomaticBackupPaused(namespace: String) throws -> Bool { paused }
    func setAutomaticBackupPaused(_ value: Bool, namespace: String) throws { paused = value }
    func acceptedTakeoverGeneration(namespace: String) throws -> String? { takeover }
    func setAcceptedTakeoverGeneration(_ generationID: String?, namespace: String) throws { takeover = generationID }
    func pendingCleanupPaths(namespace: String) throws -> [String] { cleanup }
    func setPendingCleanupPaths(_ paths: [String], namespace: String) throws { cleanup = paths }
    func pendingUpload(namespace: String) throws -> Data? { uploads[namespace] }
    func setPendingUpload(_ data: Data?, namespace: String) throws { uploads[namespace] = data }
    func stopAllAutomaticBackups() { paused = true }
    func resumeAutomaticBackupsForNewInstallation() { paused = false }
}
