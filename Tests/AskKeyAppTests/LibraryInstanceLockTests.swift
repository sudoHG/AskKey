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
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.stdout.write('ready'); sys.stdout.flush()
        sys.stdin.buffer.read(1)
        os._exit(0)
        """, directory.appendingPathComponent("instance.lock").path]
        let input = Pipe()
        let output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 5), Data("ready".utf8))
        XCTAssertNil(try LibraryInstanceLock.acquire(in: directory))
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("instance.lock").path))
        let successor = try XCTUnwrap(LibraryInstanceLock.acquire(in: directory))
        withExtendedLifetime(successor) {}
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
