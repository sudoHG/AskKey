import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

final class GrokCLIProcessLifecycleTests: GrokCLIAdapterTests {
    func testStatusTimeoutStopsIgnoredSIGTERMDescendantsAndLeavesUnrelatedProcess() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let heartbeat = fixture.directory.appendingPathComponent("heartbeat")
        let childPidFile = fixture.directory.appendingPathComponent("child.pid")
        let grok = try fixture.writeExecutable(
            name: "hang-grok-heartbeat",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              printf '%s\\n' '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              printf '%s\\n' '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              trap '' TERM
              (
                trap '' TERM HUP
                remaining=160
                while [ "$remaining" -gt 0 ]; do
                  printf x >> '\(heartbeat.path)'
                  /bin/sleep 0.05
                  remaining=$((remaining - 1))
                done
              ) &
              printf '%s\\n' "$!" > '\(childPidFile.path)'
              while [ ! -s '\(heartbeat.path)' ]; do /bin/sleep 0.01; done
              wait
            fi
            exit 1
            """
        )
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sleep")
        control.arguments = ["20"]
        try control.run()
        var leftovers: [pid_t] = [control.processIdentifier]
        defer {
            if let child = Int32((try? String(contentsOf: childPidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
               child > 1 {
                leftovers.append(child)
            }
            for pid in leftovers where pid > 1 {
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }

        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.commandTimeout = 0.8
        adapter.terminationGrace = 0.1
        expectStatusTimeout(adapter)

        guard let childPID = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(childPID)
        let goneDeadline = Date().addingTimeInterval(1)
        while Date() < goneDeadline, kill(childPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "doctor descendant must stop after status() times out")
        XCTAssertEqual(errno, ESRCH)
        let frozen = (try? Data(contentsOf: heartbeat)) ?? Data()
        XCTAssertFalse(frozen.isEmpty, "child must have started heartbeating before cleanup")
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: heartbeat), frozen, "heartbeat must stop after the descendant is reaped")
        XCTAssertEqual(kill(control.processIdentifier, 0), 0, "unrelated process must not be signaled")
        XCTAssertTrue(control.isRunning)
    }
    func testIgnoredSIGTERMAndFilledPipeDoesNotHangConnect() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let childPidFile = fixture.directory.appendingPathComponent("filled-child.pid")
        let grok = try fixture.writeExecutable(
            name: "hang-grok",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              trap '' TERM
              (while :; do printf 'untrusted-output-block\\n'; done) &
              echo $! > "\(childPidFile.path)"
              wait
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )
        var leftover: pid_t = 0
        defer { if leftover > 1 { _ = kill(leftover, SIGKILL) } }
        var adapter = fixture.adapter(grokExecutable: grok)
        // Keep the fast preflight reliable under a loaded full-suite runner;
        // the doctor branch still deterministically exceeds this timeout.
        adapter.commandTimeout = 1.0
        adapter.terminationGrace = 0.15
        let started = Date()
        expectStatusTimeout(adapter)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard let child = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftover = child
        assertProcessGone(leftover)
        XCTAssertGreaterThan(adapter.lastCapturedOutputBytes, 0)
        XCTAssertLessThanOrEqual(adapter.lastCapturedOutputBytes, BrokerLimits.maximumResponseBytes * 2)
    }
    func testZeroTerminationGraceStillReturnsTimeoutWithoutCrashing() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let childPidFile = fixture.directory.appendingPathComponent("zero-grace-child.pid")
        let doctorStarted = fixture.directory.appendingPathComponent("doctor.started")
        let grok = try fixture.writeExecutable(
            name: "hang-grok-zero-grace",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              : > "\(doctorStarted.path)"
              trap '' TERM
              dd if=/dev/zero bs=4096 2>/dev/null &
              echo $! > "\(childPidFile.path)"
              wait
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )
        var leftover: pid_t = 0
        defer { if leftover > 1 { _ = kill(leftover, SIGKILL) } }
        var adapter = fixture.adapter(grokExecutable: grok)
        // help/list share this per-command budget via try? canUseOfficialGrok();
        // 0.3s under a 115-test suite can miss doctor and return list_unavailable.
        adapter.commandTimeout = 1.0
        adapter.terminationGrace = 0
        let started = Date()
        expectStatusTimeout(adapter, doctorStarted: doctorStarted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doctorStarted.path), "status() must reach the hanging doctor")
        guard let child = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftover = child
        assertProcessGone(leftover)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testSyntheticDoctorSuccessAndNonzeroExitReapTheirDescendants() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let successChild = fixture.directory.appendingPathComponent("success-child.pid")
        let failChild = fixture.directory.appendingPathComponent("fail-child.pid")
        let success = try fixture.writeExecutable(
            name: "success-grok",
            contents: syntheticDoctorScript(
                helper: fixture.helperURL.path,
                childPidFile: successChild.path,
                doctorExit: 0
            )
        )
        let failure = try fixture.writeExecutable(
            name: "nonzero-grok",
            contents: syntheticDoctorScript(
                helper: fixture.helperURL.path,
                childPidFile: failChild.path,
                doctorExit: 1
            )
        )
        var leftovers: [pid_t] = []
        defer {
            for pid in leftovers where pid > 1 { _ = kill(pid, SIGKILL) }
        }

        let ok = try fixture.adapter(grokExecutable: success).status()
        XCTAssertFalse(ok.connected)
        XCTAssertEqual(ok.reason, "broker_unhealthy")
        guard let successPID = requireChildPID(in: successChild, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(successPID)
        assertProcessGone(successPID)

        let unhealthy = try fixture.adapter(grokExecutable: failure).status()
        XCTAssertFalse(unhealthy.connected)
        XCTAssertEqual(unhealthy.reason, "doctor_unhealthy")
        guard let failPID = requireChildPID(in: failChild, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(failPID)
        assertProcessGone(failPID)
    }
    func testOutputCaptureSerializesConcurrentReadsAndWrites() {
        let capture = OutputCapture()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<1_000 {
                    capture.bytes = i
                    _ = capture.bytes
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    }
}
