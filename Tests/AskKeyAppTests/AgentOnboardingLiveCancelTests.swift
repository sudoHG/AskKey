import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

final class AgentOnboardingLiveCancelTests: XCTestCase {
    func testLiveOperationsTaskLocalCancelStopsSleepProcessGroup() async throws {
        try await runLiveCancel(explicitRequestCancel: false)
    }

    func testLiveOperationsExplicitRequestCancelStopsSleepProcessGroup() async throws {
        try await runLiveCancel(explicitRequestCancel: true)
    }

    func testLiveCancelCleanupWhenUnrelatedControlAlreadyExited() async throws {
        try await runLiveCancel(explicitRequestCancel: false, unrelatedAlreadyExited: true)
    }

    func testFinishOwnedProcessStopsStillRunningControlAndVerifiesExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let pid = process.processIdentifier
        XCTAssertGreaterThan(pid, 1)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(kill(pid, 0), 0)
        let started = Date()
        finishOwnedProcess(process)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(process.isRunning)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testFinishOwnedProcessCompletesWhenControlAlreadyExited() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        try waitUntilOwnedProcessExited(process)
        XCTAssertFalse(process.isRunning)
        let started = Date()
        finishOwnedProcess(process)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let pid = process.processIdentifier
        XCTAssertGreaterThan(pid, 1)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testFinishOwnedProcessCompletesWhenControlAlreadyReaped() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        let started = Date()
        finishOwnedProcess(process)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(process.isRunning)
    }

    func testCancelBeforeStartDoesNotSpawn() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let executable = try makeSleepExecutable(directory: directory, pidFile: pidFile)
        let cancellation = AgentCheckCancellation()
        cancellation.cancel()
        let operations: AgentOnboardingOperations = AgentOnboardingRuntime.boundOperations(
            runCheck: { _ in
                _ = try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: executable,
                        arguments: [],
                        environment: ["PATH": "/bin:/usr/bin"],
                        timeout: 8,
                        maximumOutputBytes: 1_024
                    )
                )
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            runApply: { _, _ in
                XCTFail("cancel must not apply")
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        )
        do {
            _ = try await operations.check(.codex, cancellation)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testTimeoutIsNotMappedToCancelled() async throws {
        let operations: AgentOnboardingOperations = AgentOnboardingRuntime.boundOperations(
            runCheck: { _ in
                let result = try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["2"],
                        environment: ["PATH": "/bin:/usr/bin"],
                        timeout: 0.15,
                        maximumOutputBytes: 1_024,
                        terminationGrace: 0
                    )
                )
                XCTAssertTrue(result.timedOut)
                throw AgentOnboardingFailure.timedOut
            },
            runApply: { _, _ in
                AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        )
        do {
            _ = try await operations.check(.grok, AgentCheckCancellation())
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .timedOut)
        }
    }

    func testCoordinatorDisappearCancelsLiveCheck() async {
        let cancellationBox = CancellationBox()
        let started = LockedFlag()
        let operations: AgentOnboardingOperations = AgentOnboardingRuntime.boundOperations(
            runCheck: { _ in
                started.value = true
                _ = try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["8"],
                        environment: ["PATH": "/bin:/usr/bin"],
                        timeout: 6,
                        maximumOutputBytes: 1_024
                    )
                )
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            runApply: { _, _ in
                AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        )
        let coordinator = await MainActor.run {
            AgentOnboardingCoordinator(operations: operations)
        }
        let task = Task { @MainActor in
            await coordinator.startCheck(.cursor)
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, started.value == false {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await MainActor.run {
            coordinator.disappear()
        }
        await task.value
        let session = await MainActor.run {
            coordinator.session(for: .cursor)
        }
        XCTAssertNotEqual(session.attempt.phase, .checking)
        XCTAssertNotEqual(session.attempt.failure, .timedOut)
        XCTAssertNotEqual(session.attempt.failure, .networkUnavailable)
        _ = cancellationBox
    }

    func testMulticaRunnerCancelIsCancelledNotCommunicationFailed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("multica.pid")
        let executable = try makeSleepExecutable(directory: directory, pidFile: pidFile)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            helperIsTrusted: { _ in true },
            command: ProcessMulticaWorkspaceMCPCommand.make(executable: executable, addTimeout: 8)
        )
        let cancelled = LockedFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            cancelled.value = true
        }
        let started = Date()
        XCTAssertThrowsError(
            try RestrictedProcessCancellation.withValue({ cancelled.value }) {
                try adapter.checkStatus()
            }
        ) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
            XCTAssertFalse(error is MulticaConnectionError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        if let pid = try? pidFromFile(pidFile) {
            assertProcessGone(pid)
        }
    }

    private func runLiveCancel(explicitRequestCancel: Bool, unrelatedAlreadyExited: Bool = false) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let executable = try makeSleepExecutable(directory: directory, pidFile: pidFile)
        let unrelated = Process()
        if unrelatedAlreadyExited {
            unrelated.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try unrelated.run()
            try waitUntilOwnedProcessExited(unrelated)
            XCTAssertFalse(unrelated.isRunning)
        } else {
            unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
            unrelated.arguments = ["8"]
            try unrelated.run()
        }
        defer { finishOwnedProcess(unrelated) }

        let cancellation = AgentCheckCancellation()
        let requestCancel: (@Sendable () -> Bool)?
        if explicitRequestCancel {
            requestCancel = { cancellation.isCancelled }
        } else {
            requestCancel = nil
        }
        let operations: AgentOnboardingOperations = AgentOnboardingRuntime.boundOperations(
            runCheck: { _ in
                _ = try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: executable,
                        arguments: [],
                        environment: ["PATH": "/bin:/usr/bin"],
                        timeout: 8,
                        maximumOutputBytes: 1_024,
                        isCancelled: requestCancel
                    )
                )
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            runApply: { _, _ in
                XCTFail("cancel must not write configuration")
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        )
        let started = Date()
        let task = Task<AgentCheckReport, Error> {
            try await operations.check(.codex, cancellation)
        }
        let pid = try await waitForPID(in: pidFile)
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        assertProcessGone(pid)
        if unrelatedAlreadyExited {
            XCTAssertFalse(unrelated.isRunning)
        } else {
            XCTAssertTrue(unrelated.isRunning)
        }

        let secondPIDFile = directory.appendingPathComponent("second.pid")
        let secondExecutable = try makeSleepExecutable(directory: directory, pidFile: secondPIDFile)
        let secondCancellation = AgentCheckCancellation()
        let secondRequestCancel: (@Sendable () -> Bool)?
        if explicitRequestCancel {
            secondRequestCancel = { secondCancellation.isCancelled }
        } else {
            secondRequestCancel = nil
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            secondCancellation.cancel()
        }
        let secondOperations: AgentOnboardingOperations = AgentOnboardingRuntime.boundOperations(
            runCheck: { _ in
                _ = try RestrictedProcess.run(
                    RestrictedProcess.Request(
                        executable: secondExecutable,
                        arguments: [],
                        environment: ["PATH": "/bin:/usr/bin"],
                        timeout: 8,
                        maximumOutputBytes: 1_024,
                        isCancelled: secondRequestCancel
                    )
                )
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            runApply: { _, _ in
                AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        )
        do {
            _ = try await secondOperations.check(.cursor, secondCancellation)
            XCTFail("expected second cancelled")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        if FileManager.default.fileExists(atPath: secondPIDFile.path) {
            assertProcessGone(try pidFromFile(secondPIDFile))
        }
        if unrelatedAlreadyExited {
            XCTAssertFalse(unrelated.isRunning)
        } else {
            XCTAssertTrue(unrelated.isRunning)
        }
        kill(pid, 0)
        XCTAssertNotEqual(errno, 0)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-live-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSleepExecutable(directory: URL, pidFile: URL) throws -> URL {
        let url = directory.appendingPathComponent("sleep-cli")
        let script = """
        #!/bin/sh
        echo $$ > '\(pidFile.path)'
        exec /bin/sleep 30
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path),
               let pid = try? pidFromFile(file), pid > 1 {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "live-cancel", code: 1)
    }

    private func pidFromFile(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(text), value > 1 else {
            throw NSError(domain: "live-cancel", code: 2)
        }
        return value
    }

    private func assertProcessGone(_ pid: pid_t) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("process \(pid) still running")
    }

    private func waitUntilOwnedProcessExited(_ process: Process, timeout: TimeInterval = 2) throws {
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return }
            if pid > 1, kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "live-cancel", code: 3)
    }

    private func finishOwnedProcess(
        _ process: Process,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let pid = process.processIdentifier
        guard pid > 1 else { return }

        if process.isRunning {
            process.terminate()
        }

        if waitForOwnedProcessExit(process, timeout: timeout) {
            return
        }

        kill(pid, SIGKILL)
        if waitForOwnedProcessExit(process, timeout: 1) {
            return
        }

        XCTFail("owned process \(pid) still running after bounded cleanup", file: file, line: line)
    }

    // Let Foundation observe and reap its own child before cleanup returns.
    private func waitForOwnedProcessExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
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

private final class CancellationBox: @unchecked Sendable {}
