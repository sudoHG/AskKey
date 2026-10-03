import CryptoKit
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class HumanTextCredentialTests: XCTestCase {
    func testPermissionCanChangeWithoutRevealingOrReplacingCredentialPayload() throws {
        let vault = try makeManagedVault()
        let created = try vault.createTextCredential(
            TextCredentialInput(name: "TOKEN", value: "secret", permission: .ask),
            using: .allow
        )

        try vault.updateCredentialPermission(
            id: created.id,
            permission: .allowed,
            using: .allow
        )

        let listed = try vault.listTextCredentials()
        XCTAssertEqual(listed.first?.permission, .allowed)
        XCTAssertNil(listed.first?.value)
        XCTAssertEqual(
            try vault.revealTextCredential(id: created.id, using: .allow).value,
            "secret"
        )
    }

    func testMetadataEditPreservesUnrevealedPayloadAndPrivateNotes() throws {
        let vault = try makeManagedVault()
        let created = try vault.createBundleCredential(
            BundleCredentialInput(
                name: "Production API",
                components: [.init(name: "API_KEY", value: .text("secret"))],
                privateNotes: "owner only"
            ),
            using: .allow
        )

        try vault.updateCredentialMetadata(
            id: created.id,
            name: "Renamed API",
            usageInstructions: "release only",
            groupName: "Release",
            permission: .allowed,
            expiresAt: nil,
            using: .allow
        )

        let revealed = try vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.name, "Renamed API")
        XCTAssertEqual(revealed.usageInstructions, "release only")
        XCTAssertEqual(revealed.groupName, "Release")
        XCTAssertEqual(revealed.permission, .allowed)
        XCTAssertEqual(revealed.privateNotes, "owner only")
        XCTAssertEqual(revealed.components.first?.value, .text("secret"))
    }

    func testOneCredentialStoresTextAndFileComponentsUnderOnePermission() throws {
        let vault = try makeManagedVault()
        let created = try vault.createBundleCredential(
            BundleCredentialInput(
                name: "Production API",
                components: [
                    CredentialComponentInput(name: "API_TOKEN", value: .text("secret-token")),
                    CredentialComponentInput(
                        name: "CLIENT_CERT",
                        value: .file(filename: "client.pem", bytes: Data("certificate".utf8))
                    ),
                ]
            ),
            using: .allow
        )

        XCTAssertEqual(created.permission, .ask)
        XCTAssertEqual(created.components.map(\.name), ["API_TOKEN", "CLIENT_CERT"])
        XCTAssertEqual(created.components.map(\.kind), [.text, .file])
        XCTAssertTrue(created.components.allSatisfy { $0.value == nil })

        let revealed = try vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.components[0].value, .text("secret-token"))
        XCTAssertEqual(
            revealed.components[1].value,
            .file(filename: "client.pem", bytes: Data("certificate".utf8))
        )
    }

    func testBundleCredentialDeliversEveryComponentUnderOneRuntimeRequest() throws {
        let vault = try makeManagedVault()
        _ = try vault.createBundleCredential(
            BundleCredentialInput(
                name: "Production API",
                components: [
                    CredentialComponentInput(name: "API_TOKEN", value: .text("secret-token")),
                    CredentialComponentInput(
                        name: "CLIENT_CERT",
                        value: .file(filename: "client.pem", bytes: Data("certificate".utf8))
                    ),
                ],
                permission: .allowed
            ),
            using: .allow
        )

        let stdout = Pipe()
        let runtime = BrokerTextRuntime(resolveCredentials: { request, cancellation in
            try vault.brokerTextCredentials(for: request, cancellation: cancellation)
        })
        let result = try runtime.run(
            .init(
                command: ["/bin/sh", "-c", "printf '%s|' \"$API_TOKEN\"; cat \"$CLIENT_CERT\""],
                credentialNames: ["Production API"]
            ),
            standardOutputFD: stdout.fileHandleForWriting.fileDescriptor
        )
        try stdout.fileHandleForWriting.close()

        XCTAssertEqual(result, .exited(0))
        XCTAssertEqual(
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "secret-token|certificate"
        )
    }

    func testUnauthenticatedOnboardingSessionIsAllowedOnlyForAnEmptyVault() throws {
        let vault = try makeHarness().vault
        try vault.beginOnboardingManagementSession()
        XCTAssertFalse(vault.hasActiveManagementSession)
        _ = try vault.createTextCredential(
            TextCredentialInput(name: "EXISTING", value: "secret"),
            using: .allow
        )
        XCTAssertFalse(vault.hasActiveManagementSession)
        vault.endManagementSession()

        XCTAssertThrowsError(try vault.beginOnboardingManagementSession()) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected authentication requirement, got \(error)")
            }
        }
    }

    func testEmptyGroupsPersistEncryptedAndDeletingOneOnlyUngroupsCredentials() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        try harness.vault.createCredentialGroup("Work", using: .allow)
        _ = try harness.vault.createTextCredential(
            TextCredentialInput(name: "TOKEN", value: "secret", groupName: "Work"),
            using: .allow
        )

        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Work"])
        try harness.store.checkpoint()
        XCTAssertFalse(try harness.databaseBytes().contains(Data("Work".utf8)))

        try harness.vault.deleteCredentialGroup("Work", using: .allow)
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
        XCTAssertNil(try harness.vault.listTextCredentials().first?.groupName)
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.name), ["TOKEN"])
    }

    func testMovingCredentialBetweenGroupsPreservesEncryptedPayload() throws {
        let vault = try makeManagedVault()
        let created = try vault.createBundleCredential(
            BundleCredentialInput(
                name: "Production API",
                components: [
                    CredentialComponentInput(name: "API_KEY", value: .text("secret-token")),
                    CredentialComponentInput(name: "API_ENDPOINT", value: .text("https://api.example.com")),
                ],
                groupName: "Old"
            ),
            using: .allow
        )

        try vault.updateCredentialGroup(id: created.id, groupName: "New", using: .allow)

        XCTAssertEqual(try vault.listTextCredentials().first?.groupName, "New")
        XCTAssertEqual(
            try vault.revealTextCredential(id: created.id, using: .allow).components,
            [
                ManagedCredentialComponent(name: "API_KEY", value: .text("secret-token")),
                ManagedCredentialComponent(name: "API_ENDPOINT", value: .text("https://api.example.com")),
            ]
        )
    }

    func testExpiredRecycleBinItemsPurgeWithoutAManagementSession() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000_000))
        let vault = try makeHarness(now: clock.tick).vault
        try vault.beginManagementSession(using: .allow)
        let credential = try vault.createTextCredential(
            TextCredentialInput(name: "TOKEN", value: "secret"),
            using: .allow
        )
        try vault.deleteTextCredential(id: credential.id, using: .allow)
        vault.endManagementSession()
        clock.now.addTimeInterval(30 * 24 * 60 * 60 + 1)

        XCTAssertEqual(try vault.purgeExpiredRecycledCredentials(), 1)
        XCTAssertFalse(vault.hasActiveManagementSession)
        try vault.beginManagementSession(using: .allow)
        XCTAssertTrue(try vault.listRecycledTextCredentials().isEmpty)
    }
    func testNormalizedNameCollisionIsRejectedWithUnderstandableError() throws {
        let vault = try makeManagedVault()

        _ = try vault.createTextCredential(
            TextCredentialInput(name: "Café", value: "first"),
            using: .allow
        )

        XCTAssertThrowsError(
            try vault.createTextCredential(
                TextCredentialInput(name: " cafe\u{0301} ", value: "second"),
                using: .allow
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("café")
                    || message.localizedCaseInsensitiveContains("already"),
                "conflict error should name the credential, got: \(message)"
            )
            XCTAssertFalse(message.contains("Project"), "got: \(message)")
            XCTAssertFalse(message.contains("Environment"), "got: \(message)")
            XCTAssertFalse(message.localizedCaseInsensitiveContains("strict"), "got: \(message)")
        }
    }

    func testPersistedNameValueAndPrivateNotesAreNotOfflineEnumerable() throws {
        let harness = try makeHarness()
        try harness.vault.beginManagementSession(using: .allow)
        let name = "OpenAI Key"
        let value = "sk-fixture-plaintext"
        let notes = "personal reminder never for agents"

        _ = try harness.vault.createTextCredential(
            TextCredentialInput(
                name: name,
                value: value,
                privateNotes: notes,
                groupName: "Client App"
            ),
            using: .allow
        )

        try harness.store.checkpoint()
        let stored = try harness.databaseBytes()
        XCTAssertFalse(stored.contains(Data(name.utf8)), "display name must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data(value.utf8)), "value must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data(notes.utf8)), "private notes must not be stored in plaintext")
        XCTAssertFalse(stored.contains(Data("Client App".utf8)), "group name must not be stored in plaintext")
    }

    func testUnlockedVaultDoesNotGrantAManagementSession() throws {
        let vault = try makeHarness().vault
        let input = TextCredentialInput(name: "TOKEN", value: "secret-value")

        XCTAssertFalse(vault.hasActiveManagementSession)
        let created = try vault.createTextCredential(input, using: ManagementAuthenticator { _ in
            XCTFail("First creation in an empty vault must not request authentication")
            return false
        })
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertEqual(try vault.storedCredentialCount(), 1)
        XCTAssertNil(created.value)
        XCTAssertThrowsError(try vault.listTextCredentials())
        XCTAssertThrowsError(try vault.revealTextCredential(id: created.id, using: .allow))
        let secondInput = TextCredentialInput(name: "SECOND", value: "another-value")
        XCTAssertThrowsError(try vault.createTextCredential(secondInput, using: .allow)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected session requirement, got \(error)")
            }
        }

        XCTAssertThrowsError(try vault.beginManagementSession(using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected refused session, got \(error)")
            }
        }
        XCTAssertFalse(vault.hasActiveManagementSession)

        try vault.beginManagementSession(using: .allow)
        XCTAssertTrue(vault.hasActiveManagementSession)
        _ = try vault.createTextCredential(secondInput, using: .allow)

        vault.endManagementSession()
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertThrowsError(try vault.createTextCredential(TextCredentialInput(name: "THIRD", value: "v"), using: .allow))
        XCTAssertThrowsError(try vault.listTextCredentials())
    }

    func testManagementSessionExpiresAfterFiveIdleMinutes() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000_000))
        let vault = try makeHarness(now: clock.tick).vault
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createTextCredential(TextCredentialInput(name: "TOKEN", value: "v"), using: .allow)

        clock.now.addTimeInterval(Vault.managementSessionIdleLimit - 1)
        XCTAssertEqual(try vault.listTextCredentials().count, 1)

        clock.now.addTimeInterval(Vault.managementSessionIdleLimit + 1)
        XCTAssertThrowsError(try vault.listTextCredentials())
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertThrowsError(
            try vault.createTextCredential(TextCredentialInput(name: "OTHER", value: "v"), using: .allow)
        )
    }

    func testManagementWritesAndRevealFailClosedWithoutConfirmation() throws {
        let vault = try makeManagedVault()
        let input = TextCredentialInput(name: "TOKEN", value: "secret-value", privateNotes: "do not leak")
        // Seed the empty vault so this assertion exercises the authenticated
        // nonempty-library path, not the first-creation exception.
        let created = try vault.createTextCredential(input, using: .allow)

        XCTAssertThrowsError(try vault.createTextCredential(TextCredentialInput(name: "SECOND", value: "denied-value"), using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected management authentication failure, got \(error)")
            }
        }

        XCTAssertThrowsError(try vault.updateTextCredential(
            id: created.id, TextCredentialInput(name: "TOKEN", value: "denied-change"), using: .deny
        )) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected update authentication failure, got \(error)")
            }
        }
        XCTAssertThrowsError(try vault.deleteTextCredential(id: created.id, using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected deletion authentication failure, got \(error)")
            }
        }
        let listed = try vault.listTextCredentials()
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed[0].value, "list must not return plaintext values")
        XCTAssertNil(listed[0].privateNotes, "list must not return private notes")
        XCTAssertEqual(listed[0].name, "TOKEN")
        XCTAssertEqual(listed[0].permission, .ask)
        XCTAssertNil(listed[0].groupName)
        XCTAssertEqual(listed[0].usageInstructions, "")

        XCTAssertThrowsError(try vault.revealTextCredential(id: created.id, using: .deny)) { error in
            guard case VaultError.managementAuthenticationRequired = error else {
                return XCTFail("expected reveal to require management confirmation, got \(error)")
            }
        }

        let revealed = try vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.value, "secret-value")
        XCTAssertEqual(revealed.privateNotes, "do not leak")
    }

    func testCreateViewUpdateAndDeleteUseCredentialVocabularyAndDefaults() throws {
        let vault = try makeManagedVault()

        let created = try vault.createTextCredential(
            TextCredentialInput(name: "Deploy Token", value: "tok-1"),
            using: .allow
        )
        XCTAssertEqual(created.permission, .ask)
        XCTAssertNil(created.groupName)
        XCTAssertEqual(created.usageInstructions, "")
        XCTAssertNil(created.privateNotes)
        XCTAssertNil(created.environmentVariable)
        XCTAssertNil(created.expiresAt)
        XCTAssertEqual(created.payloadKind, .text)

        let updated = try vault.updateTextCredential(
            id: created.id,
            TextCredentialInput(
                name: "Deploy Token",
                value: "tok-2",
                usageInstructions: "export as DEPLOY_TOKEN",
                privateNotes: "from laptop",
                groupName: "Work",
                environmentVariable: "DEPLOY_TOKEN",
                permission: .allowed,
                expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            using: .allow
        )
        XCTAssertEqual(updated.groupName, "Work")
        XCTAssertEqual(updated.usageInstructions, "export as DEPLOY_TOKEN")
        XCTAssertEqual(updated.environmentVariable, "DEPLOY_TOKEN")
        XCTAssertEqual(updated.permission, .allowed)
        XCTAssertEqual(updated.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))

        let revealed = try vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.value, "tok-2")
        XCTAssertEqual(revealed.privateNotes, "from laptop")

        try vault.deleteTextCredential(id: created.id, using: .allow)
        XCTAssertTrue(try vault.listTextCredentials().isEmpty)
    }

    func testOptionalGroupsDoNotUseLegacyProjectWords() throws {
        let vault = try makeManagedVault()
        _ = try vault.createTextCredential(
            TextCredentialInput(name: "Ungrouped", value: "a"),
            using: .allow
        )
        _ = try vault.createTextCredential(
            TextCredentialInput(name: "Grouped", value: "b", groupName: "Client App"),
            using: .allow
        )

        let listed = try vault.listTextCredentials()
        XCTAssertEqual(listed.first { $0.name == "Ungrouped" }?.groupName, nil)
        XCTAssertEqual(listed.first { $0.name == "Grouped" }?.groupName, "Client App")

        let copy = CredentialManagementCopy.self
        for text in [copy.ungrouped, copy.credential, copy.credentialGroup] {
            XCTAssertFalse(text.contains("Project"))
            XCTAssertFalse(text.contains("Environment"))
            XCTAssertFalse(text.localizedCaseInsensitiveContains("strict"))
        }
        XCTAssertEqual(CredentialPermission.ask.managementLabel, copy.ask)
        XCTAssertEqual(CredentialPermission.allowed.managementLabel, copy.allowed)
        XCTAssertEqual(CredentialPermission.hidden.managementLabel, copy.hidden)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for relative in [
            "Sources/AskKeyAppKit/Views/CredentialManagementView.swift",
            "Sources/AskKeyAppKit/Views/VaultPopover.swift",
        ] {
            let viewSource = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(viewSource.contains("Project"), "\(relative) still names Project")
            XCTAssertFalse(viewSource.contains("Environments"), "\(relative) still names Environments")
            XCTAssertFalse(viewSource.localizedCaseInsensitiveContains("strict"), "\(relative) still names strict")
        }
    }

    func testEmptyControlAndOversizedNamesAreRejected() throws {
        let vault = try makeManagedVault()
        XCTAssertThrowsError(try vault.createTextCredential(TextCredentialInput(name: "  ", value: "v"), using: .allow))
        XCTAssertThrowsError(try vault.createTextCredential(TextCredentialInput(name: "Bad\nName", value: "v"), using: .allow))
        XCTAssertThrowsError(
            try vault.createTextCredential(
                TextCredentialInput(name: String(repeating: "A", count: 256), value: "v"),
                using: .allow
            )
        )
    }

    private func makeManagedVault() throws -> Vault {
        let vault = try makeHarness().vault
        try vault.beginManagementSession(using: .allow)
        return vault
    }

    private func makeHarness(now: @escaping () -> Date = Date.init) throws -> VaultHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyHumanCredentialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("vault.db")
        let store = try VaultStore(path: databaseURL.path)
        return VaultHarness(
            directory: directory,
            databaseURL: databaseURL,
            store: store,
            vault: Vault(store: store, key: VaultCrypto.generateKey(), now: now)
        )
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
    func tick() -> Date { now }
}

private struct VaultHarness {
    let directory: URL
    let databaseURL: URL
    let store: VaultStore
    let vault: Vault

    func databaseBytes() throws -> Data {
        var combined = Data()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            combined.append(try Data(contentsOf: url))
        }
        return combined
    }
}

private extension VaultStore {
    func checkpoint() throws {
        try db.write { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
