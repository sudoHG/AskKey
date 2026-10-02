import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class FileRuntimeDeliveryTests: XCTestCase {
    private static func payloadFiles(in root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func testStartingAnotherManagerPreservesLiveInstanceDeliveries() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try FileDeliveryManager(rootURL: root)
        let delivery = try first.materialize(credentialID: "live", bytes: Data("synthetic-file".utf8))
        let second = try FileDeliveryManager(rootURL: root)
        defer { first.cleanupAll(); second.cleanupAll() }
        XCTAssertEqual(try Data(contentsOf: delivery.url), Data("synthetic-file".utf8))
        let other = try second.materialize(credentialID: "other", bytes: Data([2]))
        XCTAssertNotEqual(delivery.url.deletingLastPathComponent(), other.url.deletingLastPathComponent())
        second.cleanupAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.url.path))
    }

    func testStartupSweepsOnlyUnlockedCrashedInstance() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("instance-crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data().write(to: stale.appendingPathComponent(".owner-lock"))
        try Data("synthetic-residue".utf8).write(to: stale.appendingPathComponent("payload"))
        let manager = try FileDeliveryManager(rootURL: root)
        defer { manager.cleanupAll() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testMaterializedFileUsesRandomNameMinimumPermissionsAndDeletesOnFinish() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileRuntimeDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try FileDeliveryManager(rootURL: root, ttl: 300)

        let delivery = try manager.materialize(
            credentialID: "credential-id",
            bytes: Data("private-key-bytes".utf8)
        )

        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(delivery.url), 0o600)
        XCTAssertEqual(try Data(contentsOf: delivery.url), Data("private-key-bytes".utf8))
        XCTAssertFalse(delivery.url.lastPathComponent.localizedCaseInsensitiveContains("credential"))
        XCTAssertFalse(delivery.url.path.localizedCaseInsensitiveContains("private-key"))

        delivery.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
    }

    func testTTLRevocationAndCleanupAllRemoveDeliveries() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try FileDeliveryManager(rootURL: root, ttl: 300, retryDelay: 0.01)
        let expiring = try manager.materialize(
            credentialID: "expires",
            bytes: Data([1]),
            expiresAt: Date().addingTimeInterval(0.05)
        )
        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: expiring.url.path) })

        let first = try manager.materialize(credentialID: "first", bytes: Data([2]))
        let second = try manager.materialize(credentialID: "second", bytes: Data([3]))
        manager.revoke(credentialID: "first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))

        manager.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testStartupSweepsCrashResidue() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let residue = root.appendingPathComponent(UUID().uuidString)
        try Data("leftover-secret".utf8).write(to: residue)

        _ = try FileDeliveryManager(rootURL: root, ttl: 300)

        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path))
    }

    func testDeletionFailureIsVisibleAndRetriedUntilSuccessful() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = FailingOnceRemover()
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 0.01,
            removeItem: { try remover.remove($0) }
        )
        let delivery = try manager.materialize(credentialID: "credential", bytes: Data([4]))
        let visible = expectation(
            forNotification: .askKeyFileDeliveryCleanupFailed,
            object: nil
        )

        delivery.finish()
        wait(for: [visible], timeout: 1)
        XCTAssertEqual(manager.cleanupFailures.map(\.path), [delivery.url.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.url.path))
        XCTAssertTrue(waitUntil {
            !FileManager.default.fileExists(atPath: delivery.url.path)
                && manager.cleanupFailures.isEmpty
        })
    }

    func testFailedMaterializationCleanupFailureIsManagedAndRetried() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remover = FailingOnceRemover()
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 0.01,
            removeItem: { try remover.remove($0) },
            synchronizeFile: { _ in -1 }
        )
        let visible = expectation(
            forNotification: .askKeyFileDeliveryCleanupFailed,
            object: nil
        )

        XCTAssertThrowsError(
            try manager.materialize(credentialID: "credential", bytes: Data([5]))
        )
        wait(for: [visible], timeout: 1)
        XCTAssertTrue(waitUntil {
            Self.payloadFiles(in: root).isEmpty && manager.cleanupFailures.isEmpty
        })
    }

    func testCrashSweepFailureIsVisibleAndRetriedUntilSuccessful() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let residue = root.appendingPathComponent(UUID().uuidString)
        try Data("leftover-secret".utf8).write(to: residue)
        let remover = FailingOnceRemover()

        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 0.01,
            removeItem: { try remover.remove($0) }
        )

        XCTAssertEqual(
            manager.cleanupFailures.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() },
            [residue.resolvingSymlinksInPath()]
        )
        XCTAssertTrue(waitUntil {
            !FileManager.default.fileExists(atPath: residue.path)
                && manager.cleanupFailures.isEmpty
        })
    }

    func testManagerInitializationFailureRetriesCrashSweepWithoutRestart() throws {
        let root = scratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let residue = root.appendingPathComponent(UUID().uuidString)
        try Data("leftover-secret".utf8).write(to: residue)
        let factory = FailingOnceManagerFactory(rootURL: root)
        let visible = expectation(
            forNotification: .askKeyFileDeliveryCleanupFailed,
            object: nil
        )

        let registry = FileDeliveryManagerRegistry(
            retryDelay: 0.01,
            factory: { try factory.make() }
        )

        wait(for: [visible], timeout: 1)
        XCTAssertTrue(waitUntil {
            (try? registry.get()) != nil
                && !registry.hasFailures
                && !FileManager.default.fileExists(atPath: residue.path)
        })
    }

    func testVaultDeliversFilePathOnlyToTargetAndDeletesItAfterExit() throws {
        let harness = try makeVaultHarness()
        let sourceName = "original-private-key.pem"
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Production SSH",
                snapshot: .init(
                    originalFilename: sourceName,
                    bytes: Data("private-key-bytes".utf8),
                    byteSize: 17,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        XCTAssertEqual(created.payloadKind, .file)
        let runtime = BrokerTextRuntime(resolveCredentials: { request, cancellation in
            try harness.vault.brokerTextCredentials(for: request, cancellation: cancellation)
        })
        let output = Pipe()

        XCTAssertEqual(
            try runtime.run(
                .init(
                    command: ["/bin/sh", "-c", "printf '%s\\n' \"$KEY_FILE\"; cat \"$KEY_FILE\""],
                    credentialNames: ["Production SSH"]
                ),
                standardOutputFD: output.fileHandleForWriting.fileDescriptor
            ),
            .exited(0)
        )
        try output.fileHandleForWriting.close()
        let lines = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "private-key-bytes")
        XCTAssertFalse(lines[0].localizedCaseInsensitiveContains(sourceName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lines[0]))
    }

    func testTTLExpiryBeforeSpawnFailsClosed() throws {
        let harness = try makeVaultHarness(ttl: 0.05)
        _ = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Production SSH",
                snapshot: .init(
                    originalFilename: "key.pem",
                    bytes: Data("private-key-bytes".utf8),
                    byteSize: 17,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        let marker = scratchRoot()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try harness.vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            beforeSpawn: { usleep(100_000) }
        )

        XCTAssertThrowsError(
            try runtime.run(
                .init(
                    command: ["/usr/bin/touch", marker.path],
                    credentialNames: ["Production SSH"]
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerProviderError, .requestRejected)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPreSpawnFailureDeletesMaterializedFile() throws {
        let harness = try makeVaultHarness()
        _ = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Production SSH",
                snapshot: .init(
                    originalFilename: "key.pem",
                    bytes: Data("private-key-bytes".utf8),
                    byteSize: 17,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try harness.vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            beforeSpawn: { throw BrokerTextRuntimeError.spawnFailed }
        )

        XCTAssertThrowsError(
            try runtime.run(
                .init(command: ["/usr/bin/true"], credentialNames: ["Production SSH"])
            )
        )
        XCTAssertEqual(
            Self.payloadFiles(in: harness.deliveryRoot),
            []
        )
    }

    func testMutationAndPauseDeleteMaterializedFiles() throws {
        let harness = try makeVaultHarness()
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Production SSH",
                snapshot: .init(
                    originalFilename: "key.pem",
                    bytes: Data("private-key-bytes".utf8),
                    byteSize: 17,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        let first = try resolvedFile(harness.vault)
        first.lease?.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        _ = try harness.vault.updateFileCredential(
            id: created.id,
            FileCredentialInput(
                name: "Production SSH",
                environmentVariable: "KEY_FILE",
                permission: .hidden
            ),
            using: .allow
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        _ = try harness.vault.updateFileCredential(
            id: created.id,
            FileCredentialInput(
                name: "Production SSH",
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        let second = try resolvedFile(harness.vault)
        second.lease?.finish()
        try harness.vault.deleteTextCredential(id: created.id, using: .allow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        _ = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Replacement SSH",
                snapshot: .init(
                    originalFilename: "replacement.pem",
                    bytes: Data("replacement-key".utf8),
                    byteSize: 15,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .allowed
            ),
            using: .allow
        )
        let third = try resolvedFile(harness.vault, name: "Replacement SSH")
        third.lease?.finish()
        try harness.vault.pauseAgentAccess(using: .allow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.path))
    }

    func testTimedAllowanceRevocationDeletesMaterializedFile() throws {
        let harness = try makeVaultHarness()
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Production SSH",
                snapshot: .init(
                    originalFilename: "key.pem",
                    bytes: Data("private-key-bytes".utf8),
                    byteSize: 17,
                    contentDigest: Data()
                ),
                environmentVariable: "KEY_FILE",
                permission: .ask
            ),
            using: .allow
        )
        let request = BrokerTextRunRequest(
            command: ["/usr/bin/true"],
            credentialNames: ["Production SSH"]
        )
        let ticket: BrokerApprovalTicket
        switch try harness.vault.brokerTextCredentials(
            for: request,
            cancellation: BrokerCancellation()
        ) {
        case .resolved:
            return XCTFail("ask credential should require approval")
        case .approvalRequired(let tickets):
            guard let first = tickets.first else { return XCTFail("missing approval ticket") }
            ticket = first
        }
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .timedAllow(duration: 30)
        )
        let resolution = try harness.vault.brokerTextCredentials(
            for: request,
            cancellation: BrokerCancellation()
        )
        guard case .resolved(let credentials, _, let lease) = resolution,
              let path = credentials.first?.value else {
            return XCTFail("approved file should resolve")
        }
        lease?.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        XCTAssertTrue(harness.vault.approvalRequests.revokeTimedAllowance(credentialID: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private func makeVaultHarness(ttl: TimeInterval = 300) throws -> RuntimeVaultHarness {
        let root = scratchRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try VaultStore(path: root.appendingPathComponent("vault.db").path)
        let deliveryRoot = root.appendingPathComponent("deliveries", isDirectory: true)
        let manager = try FileDeliveryManager(
            rootURL: deliveryRoot,
            ttl: ttl
        )
        let vault = Vault(
            store: store,
            key: VaultCrypto.generateKey(),
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true }),
            fileDeliveryManager: manager
        )
        try vault.beginManagementSession(using: .allow)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return RuntimeVaultHarness(vault: vault, deliveryRoot: deliveryRoot)
    }

    private func resolvedFile(
        _ vault: Vault,
        name: String = "Production SSH"
    ) throws -> (path: String, lease: BrokerTextDeliveryLease?) {
        let request = BrokerTextRunRequest(
            command: ["/usr/bin/true"],
            credentialNames: [name]
        )
        switch try vault.brokerTextCredentials(for: request, cancellation: BrokerCancellation()) {
        case .approvalRequired:
            throw NSError(domain: "FileRuntimeDeliveryTests", code: 1)
        case .resolved(let credentials, _, let lease):
            guard let path = credentials.first?.value else {
                throw NSError(domain: "FileRuntimeDeliveryTests", code: 2)
            }
            return (path, lease)
        }
    }

    private func scratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileRuntimeDeliveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status.st_mode & 0o777
    }
}

private struct RuntimeVaultHarness {
    let vault: Vault
    let deliveryRoot: URL
}

private final class FailingOnceRemover: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func remove(_ url: URL) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        try FileManager.default.removeItem(at: url)
    }
}

private final class FailingOnceManagerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let rootURL: URL
    private var shouldFail = true

    init(rootURL: URL) { self.rootURL = rootURL }

    func make() throws -> FileDeliveryManager {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        return try FileDeliveryManager(rootURL: rootURL, ttl: 300)
    }
}
