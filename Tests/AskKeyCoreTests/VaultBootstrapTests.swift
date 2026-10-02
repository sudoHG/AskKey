import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class VaultBootstrapTests: XCTestCase {
    func testAgentStartupCreatesFreshLibraryWithoutManagementSession() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        let placeholder = try VaultStore(path: try temporaryDirectory().appendingPathComponent("placeholder.db").path)
        let vault = Vault(store: placeholder)
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        let historical = paths.directory.appendingPathComponent("restore-safety/opaque")
        try FileManager.default.createDirectory(at: historical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SYNTHETIC_HISTORY".utf8).write(to: historical)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertEqual(try Data(contentsOf: historical), Data("SYNTHETIC_HISTORY".utf8))
        defer { try? vault.store.close() }
        XCTAssertFalse(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertNotNil(keys.appKey)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(try vault.brokerCredentialCatalog(cancellation: .init()).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.appendingPathComponent("vault.db").path))
    }

    func testAgentStartupLoadsCurrentLibraryWithoutManagementSessionAndIsIdempotent() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        let initial = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        let vault = Vault(store: initial.store, key: initial.key)
        _ = try vault.createTextCredential(.init(name: "TOKEN", value: "synthetic", environmentVariable: "TOKEN", permission: .allowed), using: .deny)
        vault.lock()
        XCTAssertTrue(vault.isLocked)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertFalse(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertThrowsError(try vault.listTextCredentials())
        XCTAssertEqual(try vault.brokerCredentialCatalog(cancellation: .init()).count, 1)
        vault.approvalRequests.setReadAuthenticationEnabled(false)
        vault.approvalRequests.configureAuthentication { _ in false }
        try vault.prepareAgentRuntime(paths: paths, keyStore: {
            XCTFail("Already loaded runtime must not read keys again")
            return keys
        })
        XCTAssertFalse(vault.hasActiveManagementSession)
        let ticket = try vault.approvalRequests.submit(.init(
            operationID: "startup-read", credentialID: "TOKEN", targetID: "TOKEN",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none)
        XCTAssertEqual(try vault.approvalRequests.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once
        ).state, .approved)
        try vault.beginManagementSession(using: .allow)
        try vault.pauseAgentAccess(using: .allow)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertTrue(try vault.isAgentAccessPaused())
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        vault.lock()
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        try vault.store.close()
    }

    func testFreshBootstrapRejectsPendingKeyWithoutDatabase() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        keys.pendingKey = Data(repeating: 0x42, count: 32)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingDatabase)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.pendingKey, Data(repeating: 0x42, count: 32))
        XCTAssertNil(keys.appKey)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testActivatedKeyWithoutDatabaseIsNeverReplaced() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore(appKey: Data(repeating: 0x42, count: 32))
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingDatabase)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.appKey, Data(repeating: 0x42, count: 32))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testQuiescedCurrentStoreAllowsReadsButRejectsEveryWrite() throws {
        let store = try VaultStore(path: try temporaryDirectory().appendingPathComponent("library.db").path)
        defer { try? store.close() }
        let quiesced = try store.quiescedCopy()
        defer { try? quiesced.close() }
        XCTAssertEqual(try quiesced.fetchAllProjects().count, 1)
        XCTAssertThrowsError(try quiesced.setConfigValue(key: "must_not_write", value: "blocked"))
    }

    func testClosingCurrentStoreDrainsInFlightWriteAndRejectsFutureWrites() throws {
        let store = try VaultStore(path: try temporaryDirectory().appendingPathComponent("library.db").path)
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "AskKeyStoreDrainTest", attributes: .concurrent)
        worker.async {
            defer { writeFinished.signal() }
            do {
                try store.db.write { database in
                    writeStarted.signal()
                    releaseWrite.wait()
                    try database.execute(sql: "INSERT INTO config (key, value) VALUES ('drained', 'yes')")
                }
            } catch { XCTFail("in-flight write failed: \(error)") }
        }
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        worker.async {
            do { try store.close() } catch { XCTFail("close failed: \(error)") }
            closeFinished.signal()
        }
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.1), .timedOut)
        releaseWrite.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try store.setConfigValue(key: "after_close", value: "blocked"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyBootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class MemoryAppKeyStore: AppKeyStore {
    var appKey: Data?
    var pendingKey: Data?
    var mutations = 0
    init(appKey: Data? = nil) { self.appKey = appKey }
    func loadAppKey() throws -> Data {
        guard let appKey else { throw AppKeyStoreError.missingAppKey }
        return appKey
    }
    func loadPendingKey() throws -> Data {
        guard let pendingKey else { throw AppKeyStoreError.missingPendingKey }
        return pendingKey
    }
    func savePendingKey(_ data: Data) throws { mutations += 1; pendingKey = data }
    func promotePendingKey() throws { mutations += 1; appKey = try loadPendingKey() }
    func deletePendingKey() throws { mutations += 1; pendingKey = nil }
    func deleteAppKey() throws { mutations += 1; appKey = nil }
    func deleteLegacyKey() throws { mutations += 1 }
}

func directoryBytes(_ directory: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    var result: [String: Data] = [:]
    for name in names {
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            for (child, bytes) in try directoryBytes(url) { result[name + "/" + child] = bytes }
        } else { result[name] = try Data(contentsOf: url) }
    }
    return result
}
