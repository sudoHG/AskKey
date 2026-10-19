import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit

final class LibraryInstanceLockTests: XCTestCase {
    @MainActor
    func testActivationRequestedDuringLaunchWaitsForWindowHandler() {
        let activation = LibraryInstanceActivation()
        var opened = 0
        activation.request()
        activation.request()
        XCTAssertEqual(opened, 0)
        activation.install { opened += 1 }
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testActivationUsesInstalledManagementWindowHandler() {
        let activation = LibraryInstanceActivation()
        var opened = 0
        activation.install { opened += 1 }
        activation.request()
        XCTAssertEqual(opened, 1)
    }

    @MainActor
    func testActivationRequestsAreRateLimitedWhileAcknowledgementsRemainIndependent() {
        var now: TimeInterval = 10
        let activation = LibraryInstanceActivation(now: { now })
        let reply = LibraryInstanceActivationReply()
        var opened = 0
        activation.install { opened += 1 }
        activation.request()
        now += 0.5
        activation.request()
        reply.receive(123)
        XCTAssertEqual(reply.processIdentifier, 123)
        XCTAssertEqual(opened, 1)
        now += 0.5
        activation.request()
        XCTAssertEqual(opened, 2)
    }

    func testExclusiveLockAndReleaseAcrossSeparateDescriptors() throws {
        let directory = try makeDirectory()
        var owner: LibraryInstanceLock? = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        XCTAssertNotNil(owner)
        XCTAssertNil(try LibraryInstanceLock.acquire(in: directory))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("instance.lock").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        owner = nil
        let successor = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        try withExtendedLifetime(successor) {
            XCTAssertNil(try LibraryInstanceLock.acquire(in: directory))
        }
    }

    func testProcessExitReleasesLockWithoutDeletingItsFile() throws {
        let directory = try makeDirectory()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "AskKeyAppTests.LibraryInstanceLockTests/testLockOwnerSubprocess",
                           Bundle(for: Self.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging(
            ["LIBRARY_LOCK_TEST_DIRECTORY": directory.path], uniquingKeysWith: { _, new in new }
        )
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let ready = directory.appendingPathComponent("ready")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !FileManager.default.fileExists(atPath: ready.path), child.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: ready.path) else { return XCTFail("Lock owner did not become ready") }
        XCTAssertNil(try LibraryInstanceLock.acquire(in: directory))
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("instance.lock").path))
        let successor = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        withExtendedLifetime(successor) {}
    }

    func testLockOwnerSubprocess() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBRARY_LOCK_TEST_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path)
        let owner = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        try withExtendedLifetime(owner) {
            try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"))
            _ = try FileHandle.standardInput.read(upToCount: 1)
            _exit(0) // Deliberately skip deinit; the kernel must release the actual lock.
        }
    }

    func testSpawnedTargetDoesNotInheritLibraryLock() throws {
        let directory = try makeDirectory()
        var owner: LibraryInstanceLock? = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        XCTAssertNotNil(owner)
        let target = strdup("/bin/sleep")!
        let duration = strdup("30")!
        defer { free(target); free(duration) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [target, duration, nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        // No CLOSE_DEFAULT flag or file actions: this checks O_CLOEXEC itself.
        XCTAssertEqual(posix_spawn(&pid, target, nil, nil, &arguments, &environment), 0)
        guard pid > 0 else { return }
        defer { kill(pid, SIGTERM); waitpid(pid, nil, 0) }
        owner = nil
        let successor = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        withExtendedLifetime(successor) { XCTAssertEqual(kill(pid, 0), 0) }
    }

    func testDifferentLibraryNamespacesCanEachAcquireLock() throws {
        let directory = try makeDirectory()
        let production = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        let development = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory.appendingPathComponent("dev")))
        try withExtendedLifetime((production, development)) {
            XCTAssertNil(try LibraryInstanceLock.acquire(in: directory))
        }
    }

    func testSymlinkCannotRedirectLockToAnotherFile() throws {
        let directory = try makeDirectory()
        let target = directory.appendingPathComponent("target")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("instance.lock"), withDestinationURL: target
        )
        XCTAssertThrowsError(try LibraryInstanceLock.acquire(in: directory))
        XCTAssertEqual(try Data(contentsOf: target), Data("synthetic".utf8))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
