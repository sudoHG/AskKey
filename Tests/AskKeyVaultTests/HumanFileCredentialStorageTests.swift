import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class HumanFileCredentialStorageTests: HumanFileCredentialTestSupport {
    func testCreateStoresEncryptedBytesAndLeavesSourceUnchanged() throws {
        let harness = try makeManagedHarness()
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try payload.write(to: source)
        let sourceBefore = try Data(contentsOf: source)

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source),
                privateNotes: "do not copy"
            ),
            using: .allow
        )

        XCTAssertEqual(created.payloadKind, .file)
        XCTAssertEqual(created.permission, .ask)
        XCTAssertNil(created.groupName)
        XCTAssertEqual(created.usageInstructions, "")
        XCTAssertNil(created.value)
        XCTAssertNil(created.fileBytes)
        XCTAssertNil(created.originalFilename)
        XCTAssertNil(created.privateNotes)
        XCTAssertEqual(created.byteSize, 28)
        XCTAssertEqual(created.contentDigest, Self.fixtureDigestHex)

        let listed = try harness.vault.listTextCredentials()
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed[0].fileBytes)
        XCTAssertNil(listed[0].originalFilename)

        XCTAssertThrowsError(try harness.vault.revealTextCredential(id: created.id, using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected reveal confirmation, got \(error)")
            }
        }

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.originalFilename, "id_ed25519")
        XCTAssertEqual(revealed.fileBytes, payload)
        XCTAssertEqual(revealed.privateNotes, "do not copy")
        XCTAssertEqual(revealed.contentDigest, Self.fixtureDigestHex)

        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        try harness.store.checkpoint()
        let stored = try harness.databaseBytes()
        XCTAssertFalse(stored.contains(payload), "file bytes must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("id_ed25519".utf8)), "original filename must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("Laptop SSH".utf8)), "display name must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("do not copy".utf8)), "private notes must not be stored in plaintext")
        XCTAssertEqual(try directoryNames(harness.directory), ["id_ed25519", "vault.db", "vault.db-shm", "vault.db-wal"].filter {
            FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent($0).path)
        }.sorted())
    }
    func testFailedCreateDoesNotLeaveStagingPlaintextOrChangeSource() throws {
        let harness = try makeManagedHarness()
        _ = try harness.vault.createTextCredential(
            TextCredentialInput(name: "Laptop SSH", value: "text"),
            using: .allow
        )
        let payload = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let source = harness.directory.appendingPathComponent("AuthKey.p8")
        try payload.write(to: source)
        let namesBefore = try directoryNames(harness.directory)
        let sourceBefore = try Data(contentsOf: source)

        XCTAssertThrowsError(
            try harness.vault.createFileCredential(
                FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
                using: .allow
            )
        ) { error in
            guard case VaultError.credentialNameConflict = error else {
                return XCTFail("expected name conflict, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("Project"))
            XCTAssertFalse(error.localizedDescription.contains("Environment"))
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try directoryNames(harness.directory), namesBefore)
        try harness.store.checkpoint()
        XCTAssertFalse(try harness.databaseBytes().contains(payload))
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.payloadKind), [.text])
    }
    func testReplaceRequiresConfirmationAndKeepsSourceFilesIntact() throws {
        let harness = try makeManagedHarness()
        let original = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let source = harness.directory.appendingPathComponent("id_ed25519")
        let next = harness.directory.appendingPathComponent("AuthKey.p8")
        try original.write(to: source)
        try replacement.write(to: next)

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )

        XCTAssertThrowsError(
            try harness.vault.updateFileCredential(
                id: created.id,
                FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: next)),
                using: .deny
            )
        )

        let updated = try harness.vault.updateFileCredential(
            id: created.id,
            FileCredentialInput(
                name: "Rotated Key",
                snapshot: try FileImport.freeze(url: next),
                usageInstructions: "use with CI",
                groupName: "Work",
                permission: .hidden
            ),
            using: .allow
        )
        XCTAssertEqual(updated.name, "Rotated Key")
        XCTAssertEqual(updated.groupName, "Work")
        XCTAssertEqual(updated.permission, .hidden)
        XCTAssertEqual(updated.byteSize, 5)
        XCTAssertEqual(updated.contentDigest, Self.binaryDigestHex)
        XCTAssertNil(updated.fileBytes)

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
        XCTAssertEqual(revealed.fileBytes, replacement)

        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: next), replacement)

        try harness.vault.deleteTextCredential(id: created.id, using: .allow)
        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    func testPersistedDigestIsComputedFromFileBytesNotCallerClaim() throws {
        let harness = try makeManagedHarness()
        let payload = Data("ssh-ed25519 AAAA fixture-key".utf8)
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try payload.write(to: source)
        let frozen = try FileImport.freeze(url: source)
        let lying = FileImport.FrozenFile(
            originalFilename: frozen.originalFilename,
            bytes: frozen.bytes,
            byteSize: 999,
            contentDigest: Data(repeating: 0xAB, count: 32)
        )

        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: lying),
            using: .allow
        )
        XCTAssertEqual(created.byteSize, 28)
        XCTAssertEqual(created.contentDigest, Self.fixtureDigestHex)

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, payload)
        XCTAssertEqual(revealed.contentDigest, Self.fixtureDigestHex)
    }
    func testRevealFailsClosedWhenDigestDoesNotMatchPayload() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "Laptop SSH", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )

        guard var record = try harness.store.fetchCredential(id: created.id) else {
            return XCTFail("missing credential")
        }
        record.contentDigest = Data(repeating: 0xAB, count: 32)
        try harness.store.updateCredential(record)

        XCTAssertThrowsError(try harness.vault.revealTextCredential(id: created.id, using: .allow)) { error in
            guard case VaultError.invalidFileCredential(.digestMismatch) = error else {
                return XCTFail("expected digestMismatch, got \(error)")
            }
        }
    }
}

private extension VaultStore {
    func checkpoint() throws {
        try db.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
