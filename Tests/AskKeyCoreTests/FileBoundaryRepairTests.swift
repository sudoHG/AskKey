import Darwin
import Foundation
import XCTest
@testable import AskKeyCore

final class FileBoundaryRepairTests: XCTestCase {
    func testCleanupRetainsFailureWhenParentCannotBeInspected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileBoundaryCleanup-\(UUID().uuidString)", isDirectory: true)
        defer {
            _ = chmod(root.path, S_IRWXU)
            try? FileManager.default.removeItem(at: root)
        }

        let remover = FailWithPermissionOnce()
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 60,
            removeItem: { try remover.remove($0) }
        )
        let delivery = try manager.materialize(credentialID: "credential", bytes: Data([1]))
        let instanceDirectory = delivery.url.deletingLastPathComponent()
        defer { _ = chmod(instanceDirectory.path, S_IRWXU) }

        XCTAssertEqual(chmod(instanceDirectory.path, 0), 0)
        delivery.finish()

        XCTAssertEqual(manager.cleanupFailures.map(\.path), [delivery.url.path])

        XCTAssertEqual(chmod(instanceDirectory.path, S_IRWXU), 0)
        manager.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
        XCTAssertTrue(manager.cleanupFailures.isEmpty)
    }

    func testSweepRetainsNonENOENTFailureWhenNamespaceCannotBeInspected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileBoundarySweep-\(UUID().uuidString)", isDirectory: true)
        defer {
            _ = chmod(root.path, S_IRWXU)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let residue = root.appendingPathComponent("\(UUID().uuidString)")
        try Data("residue".utf8).write(to: residue)

        let remover = SweepPermissionFailOnce(root: root, residue: residue)
        let manager = try FileDeliveryManager(
            rootURL: root,
            ttl: 300,
            retryDelay: 60,
            removeItem: { try remover.remove($0) }
        )
        defer { manager.cleanupAll() }

        XCTAssertTrue(waitUntil {
            manager.cleanupFailures.contains {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath()
                    == residue.resolvingSymlinksInPath()
            }
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: residue.path))
        manager.cleanupAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path))
        XCTAssertTrue(manager.cleanupFailures.isEmpty)
    }

    func testReplacementByFIFOAfterPathCheckDoesNotWaitForWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileBoundaryFIFO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("credential.data")
        try Data("ordinary-file".utf8).write(to: url)
        let pathCheckFinished = DispatchSemaphore(value: 0)
        let freezeFinished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<FileImport.FrozenFile, Error>?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let frozen = try FileImport.freeze(url: url) { stage in
                    guard stage == .afterPathCheck else { return }
                    try FileManager.default.removeItem(at: url)
                    guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    pathCheckFinished.signal()
                }
                resultLock.lock()
                result = .success(frozen)
                resultLock.unlock()
            } catch {
                resultLock.lock()
                result = .failure(error)
                resultLock.unlock()
            }
            freezeFinished.signal()
        }

        XCTAssertEqual(pathCheckFinished.wait(timeout: .now() + 1), .success)
        let completedWithoutWriter = freezeFinished.wait(timeout: .now() + 0.25) == .success
        if !completedWithoutWriter {
            let writer = Darwin.open(url.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(writer, 0)
            if writer >= 0 { Darwin.close(writer) }
            XCTAssertEqual(freezeFinished.wait(timeout: .now() + 1), .success)
        }
        XCTAssertTrue(completedWithoutWriter, "a replaced FIFO must not make import wait for a writer")

        resultLock.lock()
        let frozenResult = result
        resultLock.unlock()
        guard case .failure(let error) = frozenResult else {
            return XCTFail("expected the replaced FIFO to be rejected")
        }
        guard case VaultError.invalidFileCredential(.specialFile) = error else {
            return XCTFail("expected specialFile, got \(error)")
        }
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }
}

private final class FailWithPermissionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = true

    func remove(_ url: URL) throws {
        lock.lock()
        let fail = shouldFail
        shouldFail = false
        lock.unlock()
        if fail {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class SweepPermissionFailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let residue: URL
    private var shouldFail = true

    init(root: URL, residue: URL) {
        self.root = root
        self.residue = residue
    }

    func remove(_ url: URL) throws {
        lock.lock()
        let fail = shouldFail
            && url.resolvingSymlinksInPath() == residue.resolvingSymlinksInPath()
        shouldFail = false
        lock.unlock()
        if fail {
            guard chmod(root.path, 0) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                _ = chmod(self.root.path, S_IRWXU)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        try FileManager.default.removeItem(at: url)
    }
}
