import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

func syntheticDoctorScript(
    helper: String,
    childPidFile: String,
    doctorExit: Int
) -> String {
    """
    #!/usr/bin/python3 -I
    import os
    import sys
    import time
    args = sys.argv[1:]
    if args[:3] == ["mcp", "add", "--help"]:
        sys.stdout.write("--scope user\\n")
        sys.exit(0)
    if args[:2] == ["mcp", "list"]:
        sys.stdout.write('[{"command":"\(helper)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]\\n')
        sys.exit(0)
    if args[:2] == ["mcp", "doctor"]:
        child = os.fork()
        if child == 0:
            time.sleep(8)
            os._exit(0)
        with open("\(childPidFile)", "w", encoding="utf-8") as stream:
            stream.write(str(child))
        sys.stdout.write('{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}\\n')
        sys.exit(\(doctorExit))
    sys.exit(1)
    """
}

func expectStatusTimeout(
    _ adapter: GrokCLIAdapter,
    doctorStarted: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let status = try adapter.status()
        let doctor = doctorStarted.map { FileManager.default.fileExists(atPath: $0.path) }
        XCTFail(
            "expected timeout, got reason=\(status.reason) connected=\(status.connected) doctorStarted=\(String(describing: doctor))",
            file: file,
            line: line
        )
    } catch {
        guard case GrokCLIAdapterError.verificationFailed("timeout") = error else {
            XCTFail("expected timeout, got \(error)", file: file, line: line)
            return
        }
    }
}

func requireChildPID(
    in url: URL,
    until deadline: Date,
    file: StaticString = #filePath,
    line: UInt = #line
) -> pid_t? {
    let pid = waitForPID(in: url, until: deadline)
    guard pid > 1 else {
        XCTFail("no doctor descendant pid (got \(pid)); refusing to inspect pid 0", file: file, line: line)
        return nil
    }
    return pid
}

func assertProcessGone(_ pid: pid_t, timeout: TimeInterval = 1) {
    guard pid > 1 else {
        XCTFail("refusing to inspect pid \(pid) as a descendant")
        return
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, kill(pid, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) must have stopped")
    XCTAssertEqual(errno, ESRCH)
}

func waitForPID(in url: URL, until deadline: Date) -> pid_t {
    while Date() < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1 {
            return pid
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return 0
}
