import Darwin
import Foundation
import XCTest
@testable import AskKeySystem

final class RestrictedProcessTests: XCTestCase {
    func testSuccessCapturesStdout() throws {
        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["askkey-ok"],
                environment: pathEnvironment,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "askkey-ok\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testNonzeroExitReturnsStatus() throws {
        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                environment: pathEnvironment,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.timedOut)
    }

    func testTimeoutKillsAndLeavesUnrelatedProcess() throws {
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sleep")
        control.arguments = ["8"]
        try control.run()
        defer {
            control.terminate()
            control.waitUntilExit()
        }

        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["4"],
                environment: pathEnvironment,
                timeout: 0.2,
                maximumOutputBytes: 4_096,
                terminationGrace: 0.05
            )
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(control.isRunning)
        XCTAssertEqual(kill(control.processIdentifier, 0), 0)
    }

    func testCancelStopsTheOwnedProcessGroup() throws {
        let cancelled = LockedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            cancelled.value = true
        }
        let started = Date()
        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["8"],
                    environment: pathEnvironment,
                    timeout: 4,
                    maximumOutputBytes: 4_096,
                    isCancelled: { cancelled.value }
                )
            )
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTaskLocalCancelIsHonored() throws {
        let flag = LockedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            flag.value = true
        }
        XCTAssertThrowsError(
            try RestrictedProcessCancellation.withValue({ flag.value }) {
                try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["8"],
                        environment: pathEnvironment,
                        timeout: 4,
                        maximumOutputBytes: 4_096
                    )
                )
            }
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .cancelled)
        }
    }

    func testIgnoringTERMDescendantIsReaped() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")

        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sleep 8 & echo $! > '\(pidFile.path)'; wait",
                ],
                environment: pathEnvironment,
                timeout: 0.4,
                maximumOutputBytes: 4_096,
                terminationGrace: 0.1
            )
        )
        XCTAssertTrue(result.timedOut)
        let child = try requirePID(in: pidFile)
        assertProcessGone(child)
    }

    func testStderrIsCapturedOrDiscardedByFlag() throws {
        let captured = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2"],
                environment: pathEnvironment,
                timeout: 2,
                captureStderr: true,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(String(decoding: captured.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: captured.stderr, as: UTF8.self), "err")

        let discarded = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2"],
                environment: pathEnvironment,
                timeout: 2,
                captureStderr: false,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(String(decoding: discarded.stdout, as: UTF8.self), "out")
        XCTAssertTrue(discarded.stderr.isEmpty)
    }

    func testOutputCapTruncatesOrThrows() throws {
        let truncated = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=1024 count=8 2>/dev/null"],
                environment: pathEnvironment,
                timeout: 2,
                maximumOutputBytes: 100,
                truncateOutput: true
            )
        )
        XCTAssertEqual(truncated.stdout.count, 100)
        XCTAssertFalse(truncated.timedOut)

        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "dd if=/dev/zero bs=1024 count=8 2>/dev/null"],
                    environment: pathEnvironment,
                    timeout: 2,
                    maximumOutputBytes: 100,
                    truncateOutput: false
                )
            )
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .outputTooLarge)
        }
    }

    func testOutputOverflowCleansUpStillRunningDescendant() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("overflow.pid")
        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "/bin/sleep 8 & echo $! > '\(pidFile.path)'; dd if=/dev/zero bs=1024 count=8 2>/dev/null; wait",
                    ],
                    environment: pathEnvironment,
                    timeout: 3,
                    maximumOutputBytes: 64,
                    truncateOutput: false,
                    terminationGrace: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .outputTooLarge)
        }
        let child = try requirePID(in: pidFile)
        assertProcessGone(child)
    }

    func testInputBeforeSpawnAndAfterSpawnAndEarlyExit() throws {
        let echoed = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: pathEnvironment,
                standardInput: Data("prewrite\n".utf8),
                writeInputBeforeSpawn: true,
                maximumInputBytes: 4_096,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(String(decoding: echoed.stdout, as: UTF8.self), "prewrite\n")

        let after = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/cat"),
                arguments: [],
                environment: pathEnvironment,
                standardInput: Data("postwrite\n".utf8),
                writeInputBeforeSpawn: false,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(String(decoding: after.stdout, as: UTF8.self), "postwrite\n")

        let early = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: pathEnvironment,
                standardInput: Data("ignored-after-exit\n".utf8),
                writeInputBeforeSpawn: false,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        XCTAssertEqual(early.status, 0)
        XCTAssertFalse(early.timedOut)

        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    environment: pathEnvironment,
                    standardInput: Data(repeating: 1, count: 5_000),
                    writeInputBeforeSpawn: true,
                    maximumInputBytes: 4_096,
                    timeout: 2,
                    maximumOutputBytes: 4_096
                )
            )
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .inputTooLarge)
        }
    }

    func testEnvironmentAndWorkingDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s %s' \"$PWD\" \"$ASKKEY_RP\""],
                environment: ["ASKKEY_RP": "marker", "PATH": "/bin:/usr/bin"],
                currentDirectory: directory,
                timeout: 2,
                maximumOutputBytes: 4_096
            )
        )
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(stdout.contains(directory.lastPathComponent), stdout)
        XCTAssertTrue(stdout.hasSuffix(" marker"), stdout)
        XCTAssertEqual(stdout.split(separator: " ").last.map(String.init), "marker")
    }

    func testMissingExecutableAndDirectoryCleanUpWithoutKillingOthers() throws {
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sleep")
        control.arguments = ["8"]
        try control.run()
        defer {
            control.terminate()
            control.waitUntilExit()
        }

        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/no/such/askkey-restricted-process"),
                    arguments: [],
                    environment: pathEnvironment,
                    timeout: 1,
                    maximumOutputBytes: 128
                )
            )
        ) { error in
            if case .spawnFailed(let code) = error as? RestrictedProcess.Failure {
                XCTAssertEqual(code, .ENOENT)
            } else {
                XCTFail("expected spawnFailed ENOENT, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/usr/bin/true"),
                    arguments: [],
                    environment: pathEnvironment,
                    currentDirectory: URL(fileURLWithPath: "/no/such/askkey-cwd"),
                    timeout: 1,
                    maximumOutputBytes: 128
                )
            )
        ) { error in
            if case .spawnFailed(let code) = error as? RestrictedProcess.Failure {
                XCTAssertEqual(code, .ENOENT)
            } else {
                XCTFail("expected spawnFailed ENOENT, got \(error)")
            }
        }
        XCTAssertTrue(control.isRunning)
    }

    func testCodexStyleTimeoutAndOverflowKeepSeparateContracts() throws {
        let timedOut = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["3"],
                environment: pathEnvironment,
                standardInput: Data(),
                writeInputBeforeSpawn: true,
                maximumInputBytes: 4_096,
                timeout: 0.2,
                usesMonotonicClock: true,
                captureStderr: false,
                maximumOutputBytes: 1_048_576,
                truncateOutput: false,
                terminationGrace: 0
            )
        )
        XCTAssertTrue(timedOut.timedOut)

        XCTAssertThrowsError(
            try RestrictedProcess.run(
                RestrictedProcess.Request(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "dd if=/dev/zero bs=1024 count=8 2>/dev/null"],
                    environment: pathEnvironment,
                    standardInput: Data(),
                    writeInputBeforeSpawn: true,
                    maximumInputBytes: 4_096,
                    timeout: 2,
                    usesMonotonicClock: true,
                    captureStderr: false,
                    maximumOutputBytes: 100,
                    truncateOutput: false,
                    terminationGrace: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? RestrictedProcess.Failure, .outputTooLarge)
        }
    }

    func testSpawnSetupAPIsReturnCodesStayIndependentOfAmbientErrno() {
        errno = E2BIG
        var attributes: posix_spawnattr_t?
        let flags = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        XCTAssertEqual(flags, EINVAL)
        XCTAssertEqual(errno, E2BIG)
        XCTAssertEqual(RestrictedProcess.Failure.capturedSpawn(), .spawnFailed(.E2BIG))
        XCTAssertEqual(RestrictedProcess.Failure.capturedSpawn(flags), .spawnFailed(.EINVAL))

        var actions: posix_spawn_file_actions_t?
        XCTAssertEqual(posix_spawn_file_actions_init(&actions), 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        errno = E2BIG
        let dup = posix_spawn_file_actions_adddup2(&actions, -1, STDIN_FILENO)
        XCTAssertEqual(dup, EBADF)
        XCTAssertEqual(errno, E2BIG)
        XCTAssertEqual(RestrictedProcess.Failure.capturedSpawn(), .spawnFailed(.E2BIG))
        XCTAssertEqual(RestrictedProcess.Failure.capturedSpawn(dup), .spawnFailed(.EBADF))
    }

    func testRestrictedProcessUsesSpawnSetupReturnCodesNotAmbientErrno() throws {
        let sourceFiles = [
            "ByteAccumulator.swift",
            "RestrictedProcess+Cancellation.swift",
            "RestrictedProcess+Failure.swift",
            "RestrictedProcess+InteractiveFailure.swift",
            "RestrictedProcess+InteractiveRequest.swift",
            "RestrictedProcess+InteractiveSession.swift",
            "RestrictedProcess+InteractiveSpawn.swift",
            "RestrictedProcess+Output.swift",
            "RestrictedProcess+Request.swift",
            "RestrictedProcess+Result.swift",
            "RestrictedProcess+Spawn.swift",
            "RestrictedProcess.swift",
        ]
        let source = try sourceFiles.map { file in
            try String(
                contentsOf: repoRoot().appendingPathComponent("Sources/AskKeySystem/\(file)"),
                encoding: .utf8
            )
        }.joined(separator: "\n")
        XCTAssertTrue(source.contains("posix_spawnattr_setflags"))
        XCTAssertTrue(source.contains("posix_spawn_file_actions_adddup2"))
        XCTAssertFalse(
            source.contains(") == 0 else { throw Failure.capturedSpawn() }"),
            "posix_spawn setup APIs return the error number; do not discard it and reread errno"
        )
        XCTAssertTrue(source.contains("throw Failure.capturedSpawn(setFlags)"))
        XCTAssertTrue(source.contains("throw Failure.capturedSpawn(dupIn)"))
        XCTAssertTrue(source.contains("throw Failure.capturedSpawn(dupOut)"))
        XCTAssertTrue(
            source.contains("guard nullInput >= 0 else { throw Failure.capturedSpawn() }"),
            "open still reports failure with -1 and must keep reading errno"
        )
        XCTAssertTrue(
            source.contains("guard fcntl(outRead, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.capturedIO() }"),
            "fcntl still reports failure with -1 and must keep reading errno"
        )
        XCTAssertTrue(source.contains("throw RestrictedProcess.Failure.capturedIO()"))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private let pathEnvironment = ["PATH": "/bin:/usr/bin"]

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("askkey-rp-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func requirePID(in file: URL) throws -> pid_t {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           value > 1 {
            return value
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    struct MissingPID: Error {}
    throw MissingPID()
}

private func assertProcessGone(_ pid: pid_t, timeout: TimeInterval = 1) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0, errno == ESRCH { return }
        Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) should be gone")
    XCTAssertEqual(errno, ESRCH)
}
