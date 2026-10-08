import AskKeyBroker
import AskKeyVault
import CryptoKit
import Darwin
import Foundation

/// A local MCP client, never an approval provider. Every decision comes from
/// the real UI and every execution comes from the production Broker runtime.
@MainActor
final class E2EBrokerScenario {
    private let directory: URL
    private let control: URL
    private let scenario: String
    private let instanceID = UUID().uuidString
    private var helper: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var outputURL: URL?
    private var outputOffset = 0
    private var helperGeneration = 0
    private var requestID = 0
    private var targetPID: Int32?
    private var demoWorkspace: URL?
    private var scenarioTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    init(directory: URL, control: URL, scenario: String) {
        self.directory = directory
        self.control = control
        self.scenario = scenario
    }

    func start() {
        do { try recordProcess(ProcessInfo.processInfo.processIdentifier, role: "app") }
        catch { fail(error) }
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? mirrorEvidence()
                if commandExists("shutdown") {
                    await shutdown()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        guard scenario.hasPrefix("approval") else { return }
        scenarioTask = Task { [weak self] in
            guard let self else { return }
            do { try await run() }
            catch is CancellationError {} catch { fail(error) }
        }
    }

    func stop() {
        scenarioTask?.cancel()
        monitorTask?.cancel()
        stopHelper()
        removeDemoWorkspace()
    }

    private func run() async throws {
        try startHelper()
        let health = try await call("connection_status", [:], evidence: "health.json")
        try require(health.body["status"] as? String == "connected", "Broker did not report connected")
        if scenario == "approval-restart-check" {
            try await checkRestart()
            return
        }
        if scenario == "approval-metadata-screenshots" {
            try await metadataApprovalScreenshot()
            return
        }
        if scenario == "approval-organization-screenshots" {
            try await organizationApprovalScreenshot()
            return
        }
        let arguments = try makeFrozenRun()
        let pending = try await call("run", arguments, evidence: "run-pending.json")
        let ticket = try pendingTicket(pending)
        try JSONEncoder().encode(ticket).write(to: directory.appendingPathComponent("ticket.json"), options: .atomic)
        try report("approval-pending.json", ["requestID": ticket.requestID])
        if scenario == "approval-restart" { return }

        if scenario == "approval-cancel" {
            try await waitUntil { self.commandExists("cancel") }
            let cancelled = try await call("request_cancel", ticketArguments(ticket), evidence: "cancel.json")
            try require(try state(cancelled) == .cancelled, "Pending request was not cancelled")
            try await assertRejected(arguments, outcome: "cancelled")
            return
        }
        var decision = BrokerRequestState.pending
        try await waitUntil {
            let reply = try await self.call("request_status", self.ticketArguments(ticket), evidence: "status-latest.json")
            decision = try self.state(reply)
            return decision != .pending
        }
        try copyEvidence("status-latest.json", to: "status-decision.json")
        if decision == .denied {
            try await assertRejected(arguments, outcome: "denied")
            return
        }
        try require(decision == .approved, "Unexpected approval state: \(decision)")
        if scenario == "approval-disconnect" {
            try await disconnect(arguments)
            return
        }
        let first = try await call("run", arguments, evidence: "run-executed.json")
        let firstCode = try exitCode(first)
        try require(firstCode == 0, "Synthetic target failed")
        let replay = try await call("run", arguments, evidence: "run-replay.json")
        let replayCode = try exitCode(replay)
        let consumed = try await call("request_status", ticketArguments(ticket), evidence: "status-consumed.json")
        try require(try state(consumed) == .consumed, "Ticket did not reach consumed")
        try report("approval-result.json", ["outcome": "executed-once", "firstExitCode": firstCode,
            "replayExitCode": replayCode, "ticketState": "consumed"])
    }

    private func organizationApprovalScreenshot() async throws {
        // Only the marked E2E bundle's isolated synthetic library is used.
        try require(directory == E2EAppRuntime.runDirectory, "Organization fixtures require E2E isolation")
        try Vault.shared.beginManagementSession(using: .allow)
        do {
            for (name, permission) in [("Staging API", CredentialPermission.ask), ("Legacy API", .ask), ("Hidden CI Token", .hidden), ("Retired CI Token", .ask)] {
                let credential = try Vault.shared.createTextCredential(.init(name: name, value: "synthetic-organization-token",
                    groupName: "Old Services", permission: permission), using: .allow)
                if name == "Retired CI Token" { try Vault.shared.deleteTextCredential(id: credential.id, using: .allow) }
            }
        } catch {
            Vault.shared.endManagementSession()
            throw error
        }
        Vault.shared.endManagementSession()
        let reply = try await call("organize_credentials", [
            "operation_id": "organization-" + directory.lastPathComponent,
            "caller_name": "E2E Agent", "caller_purpose": "Organize the synthetic credential library",
            "operations": [["create_group": "Staging Services"],
                ["move": ["credential": "Staging API", "group": "Staging Services"]],
                ["rename_group": ["from": "Old Services", "to": "Renamed Services"]],
                ["delete_group": "Renamed Services"]]
        ], evidence: "organization-write-pending.json")
        guard !reply.isError,
              case .success(.textWriteRequest(.submitted(let ticket))) = try JSONDecoder().decode(BrokerResponse.self, from: reply.data),
              ticket.state == .pending else { throw failure("Expected one pending organization write") }
        try report("approval-pending.json", ["requestID": ticket.requestID])
        var decision = BrokerRequestState.pending
        try await waitUntil {
            let status = try await self.call("request_status", ["request_id": ticket.requestID,
                "capability": ticket.capability], evidence: "organization-status.json")
            decision = try self.state(status)
            return decision != .pending
        }
        try require(decision == .denied, "Screenshot organization write must be denied")
        try report("approval-result.json", ["outcome": "denied"])
    }

    private func metadataApprovalScreenshot() async throws {
        let reply = try await call("create_credential", [
            "operation_id": "metadata-" + directory.lastPathComponent,
            "name": "Staging API", "caller_name": "E2E Agent",
            "caller_purpose": "Save a synthetic staging credential",
            "components": [["name": "token", "text": "synthetic-metadata-token",
                "delivery": ["type": "environment_variable", "environment_variable": "STAGING_TOKEN"]]],
            "usage_instructions": "Use only for staging API requests. Consume STAGING_TOKEN; keep values out of logs.",
            "group": "Staging Services"
        ], evidence: "metadata-write-pending.json")
        guard !reply.isError,
              case .success(.textWriteRequest(.submitted(let ticket))) = try JSONDecoder().decode(BrokerResponse.self, from: reply.data),
              ticket.state == .pending else { throw failure("Expected pending metadata write") }
        try report("approval-pending.json", ["requestID": ticket.requestID])
        var decision = BrokerRequestState.pending
        try await waitUntil {
            let status = try await self.call("request_status", ["request_id": ticket.requestID,
                "capability": ticket.capability], evidence: "metadata-status.json")
            decision = try self.state(status)
            return decision != .pending
        }
        try require(decision == .denied, "Screenshot metadata write must be denied")
        try report("approval-result.json", ["outcome": "denied"])
    }

    private func makeFrozenRun() throws -> [String: Any] {
        if scenario == E2EScreenshotDemo.scenario {
            let run = try E2EScreenshotDemo.makeRun(operationID: "e2e-" + directory.lastPathComponent)
            demoWorkspace = run.workspace
            try writeJSON(run.arguments, "frozen-run.json")
            return run.arguments
        }
        let script = """
        #!/bin/sh
        set -eu
        [ "${ASKKEY_E2E_TOKEN:-}" = synthetic-e2e-value ] || exit 42
        printf '%s\\n' "$$" >> executions.txt
        printf '%s\\n' "$$" > target.pid
        if [ "$1" = hold ]; then
          /bin/sleep 30 &
          printf '%s\\n' "$!" > child.pid
          wait "$!"
        fi
        """
        let scriptURL = directory.appendingPathComponent("target.sh")
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        let arguments: [String: Any] = [
            "operation_id": "e2e-" + directory.lastPathComponent,
            "credentials": ["E2E Broker Credential"],
            "command": ["/bin/sh", scriptURL.path, scenario == "approval-disconnect" ? "hold" : "exit"],
            "cwd": directory.path, "caller_name": "E2E Agent", "caller_purpose": "Synthetic local execution"
        ]
        try writeJSON(arguments, "frozen-run.json")
        return arguments
    }

    private func assertRejected(_ arguments: [String: Any], outcome: String) async throws {
        let retry = try await call("run", arguments, evidence: "run-rejected.json")
        try require(retry.isError && retry.body["brokerCode"] as? String == "request_rejected", "Denied/cancelled run was accepted")
        try report("approval-result.json", ["outcome": outcome, "retryRejected": true])
    }

    private func disconnect(_ arguments: [String: Any]) async throws {
        _ = try send("run", arguments)
        let pidURL = directory.appendingPathComponent("target.pid")
        let childURL = directory.appendingPathComponent("child.pid")
        try await waitUntil {
            self.readPID(pidURL) != nil && self.readPID(childURL) != nil
        }
        guard let pid = readPID(pidURL) else {
            throw failure("Invalid target PID")
        }
        guard let childPID = readPID(childURL) else {
            throw failure("Invalid child PID")
        }
        try require(Darwin.getpgid(pid) == pid && Darwin.getpgid(childPID) == pid,
                    "Target and child must be alive in the same isolated process group")
        targetPID = pid
        try recordProcess(pid, role: "target")
        try recordProcess(childPID, role: "child")
        try report("target-running.json", ["pid": pid, "childPID": childPID, "processGroup": pid])
        try await waitUntil { self.commandExists("disconnect") }
        // Closing stdin alone cannot interrupt a serial MCP run. Killing this
        // exact helper closes its socket/control FD and invokes real cancellation.
        stopHelper()
        try await waitUntil(timeout: 6) { self.processGroupStopped(pid) }
        try startHelper()
        let replay = try await call("run", arguments, evidence: "run-replay.json")
        try report("approval-result.json", ["outcome": "disconnected", "targetStopped": true,
            "replayExitCode": try exitCode(replay)])
    }

    private func checkRestart() async throws {
        let ticket = try JSONDecoder().decode(BrokerApprovalTicket.self, from: Data(contentsOf: directory.appendingPathComponent("ticket.json")))
        let old = try await call("request_status", ticketArguments(ticket), evidence: "status-old-ticket.json")
        try require(old.isError && old.body["brokerCode"] as? String == "request_not_found", "Old ticket survived App restart")
        try report("restart-invalidated.json", ["oldTicketInvalid": true])
        try await waitUntil { self.commandExists("restart-retry") }
        let arguments = try dictionary(Data(contentsOf: directory.appendingPathComponent("frozen-run.json")))
        let retry = try await call("run", arguments, evidence: "run-new-pending.json")
        let newTicket = try pendingTicket(retry)
        try require(newTicket.requestID != ticket.requestID && newTicket.capability != ticket.capability, "Restart reused old ticket")
        try report("approval-result.json", ["outcome": "restart-requires-new-approval", "newTicket": true])
    }

    private struct Reply {
        let body: [String: Any]
        let data: Data
        let isError: Bool
    }

    private func startHelper() throws {
        helperGeneration += 1
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/askkey")
        process.arguments = ["mcp"]
        // Never copy the host environment into MCP requests or evidence.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "ASKKEY_DEBUG_RUN_DIRECTORY": directory.path]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardInput = pipe
        let prefix = "helper-\(UUID().uuidString)"
        let stdout = directory.appendingPathComponent(prefix + ".ndjson")
        let stderr = directory.appendingPathComponent(prefix + ".log")
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        output = try FileHandle(forWritingTo: stdout)
        errors = try FileHandle(forWritingTo: stderr)
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        helper = process
        input = pipe.fileHandleForWriting
        outputURL = stdout
        outputOffset = 0
        try recordProcess(process.processIdentifier, role: "helper")
    }

    private func stopHelper() {
        if let helper, helper.isRunning { Darwin.kill(helper.processIdentifier, SIGKILL) }
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
    }

    private func send(_ tool: String, _ arguments: [String: Any]) throws -> Int {
        guard let helper, helper.isRunning, let input else { throw failure("MCP helper is not running") }
        requestID += 1
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID,
            "method": "tools/call", "params": ["name": tool, "arguments": arguments]], options: [.sortedKeys])
        data.append(0x0a)
        try data.write(to: directory.appendingPathComponent("request-\(instanceID)-\(helperGeneration)-\(requestID).json"), options: .atomic)
        try input.write(contentsOf: data)
        return requestID
    }

    private func call(_ tool: String, _ arguments: [String: Any], evidence: String) async throws -> Reply {
        let id = try send(tool, arguments)
        var line: Data?
        try await waitUntil(timeout: 12) {
            guard let url = self.outputURL else { throw self.failure("Missing MCP output") }
            let data = try Data(contentsOf: url)
            try self.require(data.count <= 1_048_576, "MCP output exceeds fixture limit")
            if let newline = data[self.outputOffset...].firstIndex(of: 0x0a) {
                line = data.subdata(in: self.outputOffset..<newline)
                self.outputOffset = newline + 1
                return true
            }
            try self.require(self.helper?.isRunning == true, "MCP helper exited before replying")
            return false
        }
        let raw = line!
        try raw.write(to: directory.appendingPathComponent(evidence), options: .atomic)
        let envelope = try dictionary(raw)
        try require(envelope["id"] as? Int == id, "MCP response ID mismatch")
        guard let result = envelope["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]], let text = content.first?["text"] as? String else {
            throw failure("Invalid MCP envelope: \(String(decoding: raw, as: UTF8.self))")
        }
        let body = Data(text.utf8)
        return Reply(body: try dictionary(body), data: body, isError: result["isError"] as? Bool ?? false)
    }

    private func pendingTicket(_ reply: Reply) throws -> BrokerApprovalTicket {
        guard !reply.isError,
              case .approvalRequired(_, let tickets) = try JSONDecoder().decode(BrokerTextRunResult.self, from: reply.data),
              tickets.count == 1, let ticket = tickets.first, ticket.state == .pending else {
            throw failure("Expected a real pending approval ticket")
        }
        return ticket
    }

    private func state(_ reply: Reply) throws -> BrokerRequestState {
        guard !reply.isError, case .success(.requestStatus(let state)) = try JSONDecoder().decode(BrokerResponse.self, from: reply.data) else {
            throw failure("Expected a real request status")
        }
        return state
    }

    private func exitCode(_ reply: Reply) throws -> Int32 {
        guard !reply.isError, case .exited(let code) = try JSONDecoder().decode(BrokerTextRunResult.self, from: reply.data) else {
            throw failure("Expected a completed target, not an unknown outcome")
        }
        return code
    }

    private func ticketArguments(_ ticket: BrokerApprovalTicket) -> [String: Any] {
        ["request_id": ticket.requestID, "capability": ticket.capability]
    }

    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(try await predicate()) {
            try Task.checkCancellation()
            guard Date() < deadline else { throw failure("Fixture timed out") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func commandExists(_ command: String) -> Bool {
        FileManager.default.fileExists(atPath: control.appendingPathComponent("command-\(command).txt").path)
    }

    private func processGroupStopped(_ pid: Int32) -> Bool {
        let leaderGone = Darwin.kill(pid, 0) == -1 && errno == ESRCH
        let groupGone = Darwin.kill(-pid, 0) == -1 && errno == ESRCH
        return leaderGone && groupGone
    }

    private func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    private func shutdown() async {
        scenarioTask?.cancel()
        stopHelper()
        var stopped = true
        do {
            try await waitUntil(timeout: 6) {
                let helperStopped = self.helper?.isRunning != true
                return helperStopped && (self.targetPID.map(self.processGroupStopped) ?? true)
            }
        } catch { stopped = false }
        removeDemoWorkspace()
        let namespace = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.removePersistentDomain(forName: "com.sudohg.askkey.debug." + namespace)
        try? report("cleanup.json", ["processesStopped": stopped])
    }

    private func removeDemoWorkspace() {
        if let demoWorkspace { E2EScreenshotDemo.removeWorkspace(demoWorkspace) }
        demoWorkspace = nil
    }

    private func recordProcess(_ pid: Int32, role: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "uid=", "-o", "lstart=", "-o", "command="]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let identity = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        try require(process.terminationStatus == 0 && !identity.isEmpty, "Cannot record process identity")
        let url = directory.appendingPathComponent("process-identities.json")
        var records = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]]) ?? []
        records.append(["pid": pid, "role": role, "identity": identity, "processGroup": Darwin.getpgid(pid)])
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }

    private func mirrorEvidence() throws {
        for source in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 1_048_576,
                  ["json", "txt", "log", "pid", "ndjson"].contains(source.pathExtension) else { continue }
            // The target is the sole writer of executions.txt; this is a byte copy.
            try Data(contentsOf: source).write(to: control.appendingPathComponent(source.lastPathComponent), options: .atomic)
        }
    }

    private func report(_ filename: String, _ value: [String: Any]) throws {
        try mirrorEvidence()
        try writeJSON(value, filename)
        try copyEvidence(filename, to: filename)
    }

    private func copyEvidence(_ source: String, to destination: String) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent(source))
        try data.write(to: directory.appendingPathComponent(destination), options: .atomic)
        try data.write(to: control.appendingPathComponent(destination), options: .atomic)
    }

    private func writeJSON(_ value: [String: Any], _ filename: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Expected JSON object") }
        return value
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure(message) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "AskKeyE2E", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func fail(_ error: Error) { try? report("failure.json", ["error": String(describing: error)]) }
}
