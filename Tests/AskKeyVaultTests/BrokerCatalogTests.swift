import XCTest
import Darwin
import AskKeyBroker
@testable import AskKeyVault

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

        for request in [
            #"{"listProjects":{}}"#,
            #"{"listActivity":{"limit":100,"filter":{}}}"#,
            #"{"export":{"projectId":"anything"}}"#,
            #"{"decryptExport":{"envelope":"","passphrase":"anything"}}"#,
        ] {
            let frame = Data((#"{"agentContext":"attacker","request":\#(request)}"# + "\n").utf8)
            XCTAssertEqual(try sendLegacyFrame(frame, socketPath: socketPath), .failure(.resourceExhausted))
        }
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

    private func sendLegacyFrame(_ frame: Data, socketPath: String) throws -> BrokerResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(fd, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                throw BrokerSocketError.systemError("setsockopt", errno)
            }
        }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw BrokerSocketError.systemError("setsockopt", errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw BrokerSocketError.pathTooLong }
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            socketPath.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw BrokerSocketError.notRunning }
        let written = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == frame.count else { throw BrokerSocketError.systemError("write", errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        func readExactly(_ count: Int) throws -> Data {
            var bytes = Data()
            while bytes.count < count {
                guard let part = try handle.read(upToCount: count - bytes.count), !part.isEmpty else {
                    throw BrokerSocketError.noResponse
                }
                bytes.append(part)
            }
            return bytes
        }
        let length = try readExactly(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard Int(length) <= BrokerLimits.maximumResponseBytes else { throw BrokerSocketError.responseTooLarge }
        return try JSONDecoder().decode(BrokerResponse.self, from: readExactly(Int(length)))
    }
}
