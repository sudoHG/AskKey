import Darwin
import Foundation
import XCTest
import AskKeyCore
@testable import AskKeyApp

final class MulticaNetworkRecoveryTests: XCTestCase {
    func testReadOnlyListRecoversFromRealCLIOfflineMessage() throws {
        let fixture = try MulticaNetworkStub(mode: .offlineNetworkThenSuccess)
        defer { fixture.remove() }
        XCTAssertTrue(try fixture.command.list().isEmpty)
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 2)
    }

    func testReadOnlyListRecoversFromRealCLINetworkMessage() throws {
        let fixture = try MulticaNetworkStub(mode: .friendlyNetworkThenSuccess)
        defer { fixture.remove() }
        XCTAssertTrue(try fixture.command.list().isEmpty)
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 2)
    }

    func testReadOnlyListRetriesNoRouteOnceThenSucceeds() throws {
        let fixture = try MulticaNetworkStub(mode: .noRouteThenSuccess)
        defer { fixture.remove() }

        let servers = try fixture.command.list()

        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 2)
    }

    func testReadOnlyListStopsAfterThreeNoRouteAttempts() throws {
        let fixture = try MulticaNetworkStub(mode: .noRouteAlways)
        defer { fixture.remove() }

        var thrown: Error?
        do {
            _ = try fixture.command.list()
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? MulticaConnectionError, .commandFailed(.listWorkspaces))
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 3)
    }

    func testPermissionFailureDoesNotRetry() throws {
        let fixture = try MulticaNetworkStub(mode: .permissionDenied)
        defer { fixture.remove() }

        var thrown: Error?
        do {
            _ = try fixture.command.list()
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? MulticaConnectionError, .permissionDenied)
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 1)
    }

    func testCreateNoRouteRunsOnceAndRequiresRecovery() throws {
        let fixture = try MulticaNetworkStub(mode: .createNoRoute)
        defer { fixture.remove() }
        let configuration = MulticaMCPConfiguration(command: "/signed/askkey", args: ["mcp"])

        var thrown: Error?
        do {
            _ = try fixture.command.add("askkey", configuration)
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? MulticaConnectionError, .creationRecoveryRequired)
        XCTAssertEqual(try fixture.count(prefix: "workspace mcp add"), 1)
    }

    func testCancellationDuringNoRouteBackoffDoesNotStartAnotherProcess() throws {
        let fixture = try MulticaNetworkStub(mode: .noRouteThenCancel)
        defer { fixture.remove() }
        let result = NetworkCommandResult()
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { completed.signal() }
            do {
                _ = try RestrictedProcessCancellation.withValue({
                    guard let pid = fixture.firstPID() else { return false }
                    return kill(pid, 0) != 0 && errno == ESRCH
                }) {
                    try fixture.command.list()
                }
                result.succeeded()
            } catch {
                result.failed(error)
            }
        }
        try waitForFile(fixture.firstPIDFile)

        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)

        XCTAssertEqual(result.error as? AgentOnboardingFailure, .cancelled)
        XCTAssertEqual(try fixture.count(of: "workspace list --output json"), 1)
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "multica-network-test", code: 1)
    }
}

private final class MulticaNetworkStub: @unchecked Sendable {
    enum Mode: String {
        case offlineNetworkThenSuccess = "offline-network-then-success"
        case friendlyNetworkThenSuccess = "friendly-network-then-success"
        case noRouteThenSuccess = "no-route-then-success"
        case noRouteAlways = "no-route-always"
        case permissionDenied = "permission-denied"
        case createNoRoute = "create-no-route"
        case noRouteThenCancel = "no-route-then-cancel"
    }

    let root: URL
    let executable: URL
    let trace: URL
    let firstPIDFile: URL

    init(mode: Mode) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-multica-network-\(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("multica")
        trace = root.appendingPathComponent("calls")
        firstPIDFile = root.appendingPathComponent("first.pid")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        TRACE="\(trace.path)"
        MODE="\(mode.rawValue)"
        printf '%s\\n' "$*" >> "$TRACE"
        count=$(grep -c '^workspace list --output json$' "$TRACE" 2>/dev/null || true)

        if [ "$1 $2 $3" = "workspace list --output" ]; then
          if [ "$MODE" = "offline-network-then-success" ] && [ "$count" -eq 1 ]; then
            echo 'Could not reach the Multica server. Check your network connection.' >&2
            exit 2
          fi
          if [ "$MODE" = "friendly-network-then-success" ] && [ "$count" -eq 1 ]; then
            echo 'Could not connect to the Multica server. Make sure the server address is correct and reachable.' >&2
            exit 2
          fi
          if [ "$MODE" = "no-route-then-success" ] && [ "$count" -eq 1 ]; then
            echo 'dial tcp 198.51.100.7:443: connect: no route to host' >&2
            exit 1
          fi
          if [ "$MODE" = "no-route-always" ]; then
            echo 'dial tcp 198.51.100.7:443: connect: no route to host' >&2
            exit 1
          fi
          if [ "$MODE" = "permission-denied" ]; then
            echo 'permission denied' >&2
            exit 1
          fi
          if [ "$MODE" = "no-route-then-cancel" ] && [ "$count" -eq 1 ]; then
            echo 'dial tcp 198.51.100.7:443: connect: no route to host' >&2
            printf '%s\\n' "$$" > "\(firstPIDFile.path)"
            exit 1
          fi
          printf '[{"id":"workspace-1","name":"Studio"}]'
          exit 0
        fi

        if [ "$1 $2 $3" = "workspace mcp list" ]; then
          printf '[]'
          exit 0
        fi

        if [ "$MODE" = "create-no-route" ] && [ "$1 $2 $3" = "workspace mcp add" ]; then
          echo 'dial tcp 198.51.100.7:443: connect: no route to host' >&2
          exit 1
        fi

        exit 64
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var command: MulticaWorkspaceMCPCommand {
        ProcessMulticaWorkspaceMCPCommand.make(executable: executable, addTimeout: 3)
    }

    func count(of line: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: trace.path) else { return 0 }
        let contents = try String(contentsOf: trace, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).filter { $0 == line }.count
    }

    func count(prefix: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: trace.path) else { return 0 }
        let contents = try String(contentsOf: trace, encoding: .utf8)
        return contents.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }.count
    }

    func firstPID() -> pid_t? {
        guard let text = try? String(contentsOf: firstPIDFile, encoding: .utf8),
              let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 1 else {
            return nil
        }
        return value
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class NetworkCommandResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func succeeded() {
        lock.lock()
        storedError = nil
        lock.unlock()
    }

    func failed(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
