import XCTest
import Foundation
import Darwin
@testable import AskKeyCore

final class ReviewCleanupLeaseTests: XCTestCase {
    func testRetryHoldsCrashResidueOwnerLeaseThroughRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewCleanupLease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let residue = root.appendingPathComponent("instance-stale")
        try FileManager.default.createDirectory(at: residue, withIntermediateDirectories: true)
        try Data().write(to: residue.appendingPathComponent(".owner-lock"))
        try Data("synthetic".utf8).write(to: residue.appendingPathComponent("material"))
        let remover = LeaseCheckingRemover(residue: residue)
        let manager = try FileDeliveryManager(rootURL: root, retryDelay: 60, removeItem: { try remover.remove($0) })
        XCTAssertEqual(manager.cleanupFailures.count, 1)
        manager.cleanupAll()
        XCTAssertTrue(remover.sawLockedOwnerAtRemoval)
        XCTAssertTrue(manager.cleanupFailures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: residue.path))
    }

    func testMissingOwnerLockDoesNotHideRemainingCrashMaterial() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewCleanupLease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let residue = root.appendingPathComponent("instance-missing-owner")
        try FileManager.default.createDirectory(at: residue, withIntermediateDirectories: true)
        let material = residue.appendingPathComponent("material")
        try Data("synthetic".utf8).write(to: material)
        let manager = try FileDeliveryManager(rootURL: root, retryDelay: 60)
        XCTAssertEqual(manager.cleanupFailures.count, 1)
        manager.cleanupAll()
        XCTAssertEqual(manager.cleanupFailures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: material.path))
        try FileManager.default.removeItem(at: residue)
        manager.cleanupAll()
        XCTAssertTrue(manager.cleanupFailures.isEmpty)
    }
}

private final class LeaseCheckingRemover: @unchecked Sendable {
    private let residue: URL
    private let lock = NSLock()
    private var shouldFail = true
    private(set) var sawLockedOwnerAtRemoval = false
    init(residue: URL) { self.residue = residue }

    func remove(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        if url.lastPathComponent == residue.lastPathComponent {
            if shouldFail { shouldFail = false; throw POSIXError(.EACCES) }
            let fd = Darwin.open(residue.appendingPathComponent(".owner-lock").path, O_RDWR | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(fd) }
            let result = flock(fd, LOCK_EX | LOCK_NB)
            sawLockedOwnerAtRemoval = result != 0 && (errno == EWOULDBLOCK || errno == EAGAIN)
        }
        try FileManager.default.removeItem(at: url)
    }
}
