import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class BrokerCatalogTests: XCTestCase {
    func testCatalogExcludesHiddenCredentialsAndAllSensitiveMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: VaultCrypto.generateKey()
        )
        try vault.beginManagementSession(using: .allow)
        let visible = try vault.createTextCredential(
            .init(
                name: "VISIBLE",
                value: "saved-plaintext",
                usageInstructions: "Use for builds",
                privateNotes: "human-only",
                groupName: "Production",
                environmentVariable: "API_KEY",
                permission: .ask,
                expiresAt: Date(timeIntervalSince1970: 1)
            ),
            using: .allow
        )
        _ = try vault.createTextCredential(
            .init(name: "HIDDEN", value: "hidden-plaintext", permission: .hidden),
            using: .allow
        )
        vault.endManagementSession()

        XCTAssertEqual(
            try vault.brokerCredentialCatalog(now: Date(timeIntervalSince1970: 2)),
            [.init(credentialID: visible.id, name: "VISIBLE", payloadKind: .text, usageInstructions: "Use for builds", environmentVariable: "API_KEY", expired: true, components: [.init(name: "API_KEY", payloadKind: .text, delivery: .environmentVariable("API_KEY"))])]
        )
    }

    func testPublicSocketCannotSpeakTheLegacyBroadVaultProtocol() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: VaultCrypto.generateKey()
        )
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createTextCredential(
            .init(name: "VISIBLE", value: "must-not-cross-socket", privateNotes: "private", groupName: "sensitive-group"),
            using: .allow
        )
        vault.endManagementSession()

        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { try vault.brokerCredentialCatalog(cancellation: $0) },
                requestStatus: { _, _ in nil }
            )
        )
        try server.start()
        defer { server.stop() }

        let response = try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog"))
        let bytes = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains("VISIBLE"))
        for forbidden in ["must-not-cross-socket", "private", "sensitive-group"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }

        let legacy = VaultSocketClient(socketPath: socketPath, agentContext: "attacker")
        XCTAssertThrowsError(try legacy.send(.listProjects))
        XCTAssertThrowsError(try legacy.send(.listActivity(limit: 100, filter: .init())))
        XCTAssertThrowsError(try legacy.send(.export(projectId: "anything", passphrase: nil)))
        XCTAssertThrowsError(try legacy.send(.decryptExport(envelope: Data(), passphrase: "anything")))
    }

    func testCatalogFailsClosedForUnknownStoredPermission() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        let vault = Vault(store: store, key: VaultCrypto.generateKey())
        try vault.beginManagementSession(using: .allow)
        let credential = try vault.createTextCredential(.init(name: "K", value: "v"), using: .allow)
        var record = try XCTUnwrap(store.fetchCredential(id: credential.id))
        record.permission = "future-unknown-value"
        try store.updateCredential(record)
        vault.endManagementSession()

        XCTAssertThrowsError(try vault.brokerCredentialCatalog())
    }

    func testMultipleCatalogTimeoutRoundsKeepSharedDatabaseQueueBoundedAndHealthAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        let vault = Vault(store: store, key: VaultCrypto.generateKey())
        let databaseEntered = DispatchSemaphore(value: 0)
        let databaseRelease = DispatchSemaphore(value: 0)
        let databaseGroup = DispatchGroup()
        databaseGroup.enter()
        DispatchQueue.global().async {
            _ = try? store.db.write { _ in
                databaseEntered.signal()
                databaseRelease.wait()
            }
            databaseGroup.leave()
        }
        XCTAssertEqual(databaseEntered.wait(timeout: .now() + 2), .success)

        let exited = DispatchSemaphore(value: 0)
        let socketPath = "/tmp/askkey-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { cancellation in
                    defer { exited.signal() }
                    return try vault.brokerCredentialCatalog(cancellation: cancellation)
                },
                requestStatus: { _, _ in nil }
            )
        )
        defer {
            databaseRelease.signal()
            server.stop()
            _ = databaseGroup.wait(timeout: .now() + 2)
            try? store.close()
        }
        try server.start()

        for _ in 0..<4 {
            let clients = DispatchGroup()
            for _ in 0..<BrokerLimits.maximumConcurrentRequests {
                clients.enter()
                DispatchQueue.global().async {
                    _ = try? BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "catalog"))
                    clients.leave()
                }
            }
            XCTAssertEqual(clients.wait(timeout: .now() + 3), .success)
            for _ in 0..<BrokerLimits.maximumConcurrentRequests {
                XCTAssertEqual(exited.wait(timeout: .now() + 1), .success)
            }
            XCTAssertEqual(
                store.pendingBrokerCatalogReadCount,
                BrokerLimits.maximumConcurrentRequests
            )
            XCTAssertEqual(
                try BrokerSocketClient(socketPath: socketPath).send(.init(version: 1, method: "health")),
                .success(.health(.init(version: BrokerProtocolVersion.current, status: "ok")))
            )
        }
    }
}
