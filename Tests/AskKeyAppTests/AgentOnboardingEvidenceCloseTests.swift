import AppKit
import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

final class AgentOnboardingEvidenceCloseTests: XCTestCase {
    override func tearDown() {
        OnboardingTerminationGate.reply = nil
        super.tearDown()
    }

    func testTerminateLaterApplyFailureRepliesExactlyOnceThroughAppGate() async {
        let replies = LockedMutationCount()
        OnboardingTerminationGate.reply = { _ in
            replies.add()
        }
        let gate = CloseApplyGate()
        let probe = RepairCloseProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: closeSamplePlan(client),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            await gate.wait()
            throw AgentOnboardingFailure.verificationFailed
        }
        let coordinator = await MainActor.run {
            AgentOnboardingCoordinator(operations: probe.operations)
        }
        await coordinator.startCheck(.codex)
        let confirm = Task { await coordinator.confirm(.codex) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if probe.applyCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let decision = await MainActor.run {
            OnboardingTerminationGate.shouldTerminate(hasInFlightWrite: coordinator.hasInFlightWrite) {
                coordinator.writeSettledHandler = $0
            }
        }
        XCTAssertEqual(decision, .terminateLater)
        gate.release()
        await confirm.value
        XCTAssertEqual(replies.value, 1)
        XCTAssertEqual(probe.applyCount, 1)
        await MainActor.run { coordinator.notifyWriteSettledIfNeeded() }
        XCTAssertEqual(replies.value, 1)
        let session = await MainActor.run { coordinator.session(for: .codex) }
        XCTAssertEqual(session.attempt.failure, .verificationFailed)
    }

    @MainActor
    func testJournalRereadInNewProcessDoesNotNeedNetwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e3-journal-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent(
            "client-backups/multica-recovery",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let record = MulticaRecoveryJournal.Record(
            operationID: "op-e3",
            workspaceID: "ws-e3",
            serverName: "askkey",
            agentIDs: ["agent-1"],
            phase: "restore_failed",
            createdServerID: "srv-keep",
            assignedAgentIDs: []
        )
        try MulticaRecoveryJournal.write(record, to: recovery)
        let file = recovery.appendingPathComponent("pending.json")
        let output = root.appendingPathComponent("reread.txt")
        let source = root.appendingPathComponent("reread.c")
        try """
        #include <stdio.h>
        int main(int argc, char **argv) {
            if (argc < 3) return 2;
            FILE *in = fopen(argv[1], "r");
            if (!in) return 3;
            FILE *out = fopen(argv[2], "w");
            if (!out) { fclose(in); return 4; }
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
            fclose(in);
            fclose(out);
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("reread")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compile.arguments = [source.path, "-o", binary.path]
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        let run = Process()
        run.executableURL = binary
        run.arguments = [file.path, output.path]
        try run.run()
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("restore_failed"))
        XCTAssertTrue(text.contains("srv-keep"))
        let mutations = LockedMutationCount()
        let coordinator = AgentOnboardingCoordinator(operations: AgentOnboardingOperations(
            check: { _, _ in
                mutations.add()
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            apply: { _, _, _ in
                mutations.add()
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .cancelled }
        ))
        AgentOnboardingRuntime.adoptPendingRecovery(into: coordinator, supportDirectory: root)
        XCTAssertEqual(mutations.value, 0)
        let session = coordinator.session(for: .multica)
        XCTAssertEqual(session.attempt.phase, .recoveryRequired)
        XCTAssertEqual(session.attempt.changeStatus, .restoreFailed)
        XCTAssertEqual(session.attempt.failure, .restoreFailed)
    }
}

private final class CloseApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func release() {
        lock.withLock {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private final class LockedMutationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func add() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

private final class RepairCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var applies = 0
    var checkHandler: (@Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport)?
    var applyHandler: (@Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport)?
    var applyCount: Int { lock.withLock { applies } }

    var operations: AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { client, cancellation in
                if let checkHandler = self.checkHandler {
                    return try await checkHandler(client, cancellation)
                }
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            apply: { client, plan, cancellation in
                self.lock.withLock { self.applies += 1 }
                if let applyHandler = self.applyHandler {
                    return try await applyHandler(client, plan, cancellation)
                }
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .confirmed }
        )
    }
}

private func closeSamplePlan(_ client: AgentClient) -> AgentOnboardingPlan {
    AgentOnboardingPlan(
        client: client,
        createdAt: Date(timeIntervalSince1970: 1),
        targetIdentity: client.rawValue,
        scopeSummary: "scope",
        agentIDs: ["agent-1"],
        agentNames: ["开发"],
        workspaceID: client == .multica ? "ws-1" : nil,
        workspaceName: client == .multica ? "Studio" : nil,
        serverID: nil,
        createsServer: client == .multica,
        configurationPresent: false,
        verifiesOnly: false,
        preconditionSummary: "backup",
        activeAgentFingerprint: client == .multica ? "agent-1" : ""
    )
}
