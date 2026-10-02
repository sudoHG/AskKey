import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

@MainActor
final class AgentOnboardingReviewRepairTests: XCTestCase {
    override func tearDown() {
        MulticaRecoveryJournal.testWriteInterceptor = nil
        super.tearDown()
    }

    func testRestoreFailedCheckWithPlanDoesNotUnlockConfirm() async {
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        coordinator.adoptRecovery(
            .codex,
            result: AgentLastKnownResult(
                outcome: .notConfigured,
                checkedAt: Date(timeIntervalSince1970: 10),
                targetSummary: "Codex"
            ),
            failure: .restoreFailed,
            change: .restoreFailed
        )
        await coordinator.startCheck(.codex)
        let session = coordinator.session(for: .codex)
        XCTAssertEqual(session.attempt.changeStatus, .restoreFailed)
        XCTAssertEqual(session.attempt.phase, .recoveryRequired)
        XCTAssertNotEqual(session.attempt.phase, .readyToConfirm)
        await coordinator.confirm(.codex)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testRemoteUnknownCheckWithPlanDoesNotUnlockConfirm() async {
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .workspaceConfigured,
                targetSummary: "ws",
                plan: samplePlan(client),
                failure: nil
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        coordinator.adoptRecovery(
            .multica,
            result: AgentLastKnownResult(
                outcome: .configuredUnverified,
                checkedAt: Date(timeIntervalSince1970: 10),
                targetSummary: "ws"
            ),
            failure: .remoteUnknown,
            change: .remoteUnknown
        )
        await coordinator.startCheck(.multica)
        XCTAssertEqual(coordinator.session(for: .multica).attempt.changeStatus, .remoteUnknown)
        XCTAssertEqual(coordinator.session(for: .multica).attempt.phase, .recoveryRequired)
        await coordinator.confirm(.multica)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testExistingConfigSuccessAfterRecoveryStillLocked() async {
        let probe = RepairProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .verifiedConnected,
                targetSummary: "Codex",
                plan: nil,
                failure: nil
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        coordinator.adoptRecovery(
            .codex,
            result: AgentLastKnownResult(
                outcome: .notConfigured,
                checkedAt: Date(timeIntervalSince1970: 1),
                targetSummary: "Codex"
            ),
            failure: .restoreFailed,
            change: .restoreFailed
        )
        await coordinator.startCheck(.codex)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.changeStatus, .restoreFailed)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.phase, .recoveryRequired)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.failure, .restoreFailed)
        XCTAssertEqual(coordinator.session(for: .codex).lastKnownResult?.outcome, .verifiedConnected)
        await coordinator.confirm(.codex)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testCancelCheckDuringRecoveryKeepsRequiredPhase() async {
        let gate = RepairGate()
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            await gate.wait()
            return AgentCheckReport(
                outcome: .verifiedConnected,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        coordinator.adoptRecovery(
            .codex,
            result: AgentLastKnownResult(
                outcome: .notConfigured,
                checkedAt: Date(timeIntervalSince1970: 1),
                targetSummary: "Codex"
            ),
            failure: .restoreFailed,
            change: .restoreFailed
        )
        let check = Task { await coordinator.startCheck(.codex) }
        await waitUntil { coordinator.session(for: .codex).attempt.phase == .checking }
        coordinator.cancelCheck(.codex)
        await gate.release()
        await check.value
        let session = coordinator.session(for: .codex)
        XCTAssertEqual(session.attempt.phase, .recoveryRequired)
        XCTAssertEqual(session.attempt.changeStatus, .restoreFailed)
        XCTAssertEqual(session.attempt.failure, .restoreFailed)
        XCTAssertNil(session.plan)
        await coordinator.confirm(.codex)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testStructuredVerificationFailureKeepsSuccessfulLastKnown() async {
        let probe = RepairProbe()
        let checks = LockedCounter()
        probe.checkHandler = { _, _ in
            let count = checks.increment()
            if count == 1 {
                return AgentCheckReport(
                    outcome: .verifiedConnected,
                    targetSummary: "kept-target",
                    plan: nil,
                    failure: nil
                )
            }
            return AgentCheckReport(
                outcome: .existingConfigUnverified,
                targetSummary: "new-target",
                plan: nil,
                failure: .verificationFailed
            )
        }
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = AgentOnboardingCoordinator(
            operations: probe.operations,
            clock: { checkedAt }
        )
        await coordinator.startCheck(.cursor)
        await coordinator.startCheck(.cursor)
        let session = coordinator.session(for: .cursor)
        XCTAssertEqual(session.lastKnownResult?.outcome, .verifiedConnected)
        XCTAssertEqual(session.lastKnownResult?.targetSummary, "kept-target")
        XCTAssertEqual(session.lastKnownResult?.checkedAt, checkedAt)
        XCTAssertEqual(session.attempt.phase, .needsAction)
        XCTAssertEqual(session.attempt.failure, .verificationFailed)
    }

    func testVerificationFailureWithoutPriorResultRecordsThisCheck() async {
        let probe = RepairProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .existingConfigUnverified,
                targetSummary: "Cursor",
                plan: nil,
                failure: .verificationFailed
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.cursor)
        XCTAssertEqual(coordinator.session(for: .cursor).lastKnownResult?.outcome, .existingConfigUnverified)
    }

    func testExpiredSessionAfterAuthDoesNotApply() async {
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.sessionValid = false
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.grok)
        await coordinator.confirm(.grok)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertEqual(coordinator.session(for: .grok).attempt.failure, .permissionDenied)
        XCTAssertEqual(coordinator.session(for: .grok).attempt.phase, .needsAction)
    }

    func testTerminateLaterAuthCancelRepliesOnceWithZeroApply() async {
        let gate = RepairGate()
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.authenticateHandler = {
            await gate.wait()
            return .cancelled
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        var replies = 0
        coordinator.writeSettledHandler = { replies += 1 }
        let confirm = Task { await coordinator.confirm(.codex) }
        await waitUntil { coordinator.session(for: .codex).attempt.phase == .authenticating }
        await gate.release()
        await confirm.value
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(probe.applyCount, 0)
        coordinator.notifyWriteSettledIfNeeded()
        XCTAssertEqual(replies, 1)
    }

    func testTerminateLaterAuthFailureRepliesOnce() async {
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.authenticateHandler = { .failed }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        var replies = 0
        coordinator.writeSettledHandler = { replies += 1 }
        await coordinator.confirm(.codex)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testTerminateLaterAbandonDuringAuthRepliesOnce() async {
        let gate = RepairGate()
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.authenticateHandler = {
            await gate.wait()
            return .confirmed
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        var replies = 0
        coordinator.writeSettledHandler = { replies += 1 }
        let confirm = Task { await coordinator.confirm(.codex) }
        await waitUntil { coordinator.session(for: .codex).attempt.phase == .authenticating }
        coordinator.abandonOperation(for: .codex, returningTo: .readyToConfirm)
        await gate.release()
        await confirm.value
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testApplySuccessRepliesAfterWriteAndReadonlyCheckDoesNotBlock() async {
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            AgentApplyReport(
                outcome: .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: "Codex"
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        var replies = 0
        coordinator.writeSettledHandler = { replies += 1 }
        await coordinator.startCheck(.cursor)
        XCTAssertEqual(replies, 0)
        await coordinator.startCheck(.codex)
        await coordinator.confirm(.codex)
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(probe.applyCount, 1)
    }

    func testSecondWriteKeepsTerminateUntilBothSettle() async {
        let applyGate = RepairGate()
        let probe = RepairProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: samplePlan(client),
                failure: nil
            )
        }
        probe.applyHandler = { client, _, _ in
            if client == .codex {
                await applyGate.wait()
            }
            return AgentApplyReport(
                outcome: .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: client.rawValue
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        await coordinator.startCheck(.grok)
        var replies = 0
        coordinator.writeSettledHandler = { replies += 1 }
        let first = Task { await coordinator.confirm(.codex) }
        await waitUntil { coordinator.session(for: .codex).attempt.phase == .applying }
        await coordinator.confirm(.grok)
        XCTAssertEqual(replies, 0)
        await applyGate.release()
        await first.value
        XCTAssertEqual(replies, 1)
    }

    func testJournalAtomicReplaceKeepsContentAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = MulticaRecoveryJournal.Record(
            operationID: "old",
            workspaceID: "ws",
            serverName: "askkey",
            agentIDs: ["a"],
            phase: "starting",
            createdServerID: nil,
            assignedAgentIDs: []
        )
        let second = MulticaRecoveryJournal.Record(
            operationID: "new",
            workspaceID: "ws",
            serverName: "askkey",
            agentIDs: ["a"],
            phase: "created",
            createdServerID: "srv",
            assignedAgentIDs: []
        )
        try MulticaRecoveryJournal.write(first, to: directory)
        try MulticaRecoveryJournal.write(second, to: directory)
        let loaded = try XCTUnwrap(MulticaRecoveryJournal.load(from: directory))
        XCTAssertEqual(loaded, second)
        let file = directory.appendingPathComponent("pending.json")
        var fileInfo = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &fileInfo) }, 0)
        XCTAssertEqual(fileInfo.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        var dirInfo = stat()
        XCTAssertEqual(directory.path.withCString { lstat($0, &dirInfo) }, 0)
        XCTAssertEqual(dirInfo.st_mode & 0o777, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testJournalWriteFailureKeepsPreviousRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-\(UUID().uuidString)", isDirectory: true)
        defer {
            _ = directory.path.withCString { chflags($0, 0) }
            _ = directory.path.withCString { chmod($0, S_IRWXU) }
            try? FileManager.default.removeItem(at: directory)
        }
        let first = MulticaRecoveryJournal.Record(
            operationID: "keep",
            workspaceID: "ws",
            serverName: "askkey",
            agentIDs: [],
            phase: "starting",
            createdServerID: nil,
            assignedAgentIDs: []
        )
        try MulticaRecoveryJournal.write(first, to: directory)
        XCTAssertEqual(directory.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }, 0)
        XCTAssertThrowsError(
            try MulticaRecoveryJournal.write(
                .init(
                    operationID: "lost",
                    workspaceID: "ws",
                    serverName: "askkey",
                    agentIDs: [],
                    phase: "created",
                    createdServerID: "x",
                    assignedAgentIDs: []
                ),
                to: directory
            )
        )
        XCTAssertEqual(directory.path.withCString { chflags($0, 0) }, 0)
        XCTAssertEqual(MulticaRecoveryJournal.load(from: directory)?.operationID, "keep")
        XCTAssertEqual(MulticaRecoveryJournal.load(from: directory)?.phase, "starting")
    }

    func testJournalRejectsSymlinkWithoutFollowing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-\(UUID().uuidString)", isDirectory: true)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-target-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: target)
        let pending = directory.appendingPathComponent("pending.json")
        try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: target)
        XCTAssertThrowsError(
            try MulticaRecoveryJournal.write(
                .init(
                    operationID: "nope",
                    workspaceID: "ws",
                    serverName: "askkey",
                    agentIDs: [],
                    phase: "starting",
                    createdServerID: nil,
                    assignedAgentIDs: []
                ),
                to: directory
            )
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "secret")
        XCTAssertNil(MulticaRecoveryJournal.load(from: directory))
    }

    func testJournalWriteFailureBeforeRemoteCreateIsZeroMutation() throws {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: recovery) }
        FileManager.default.createFile(atPath: recovery.path, contents: Data(), attributes: nil)
        let probe = MutationProbe(existing: false)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command,
            recoveryDirectory: recovery
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        XCTAssertThrowsError(try adapter.commit(plan))
        XCTAssertEqual(probe.addCount, 0)
        XCTAssertEqual(probe.assignCount, 0)
    }

    func testCreatedPhaseJournalFailureKeepsUnknownEvidenceWithoutDelete() throws {
        let recovery = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-journal-\(UUID().uuidString)", isDirectory: true)
        defer {
            MulticaRecoveryJournal.testWriteInterceptor = nil
            try? FileManager.default.removeItem(at: recovery)
        }
        let probe = MutationProbe(existing: false)
        MulticaRecoveryJournal.testWriteInterceptor = { record in
            if record.phase == "created" {
                throw MulticaConnectionError.communicationFailed
            }
        }
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command,
            recoveryDirectory: recovery
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        XCTAssertThrowsError(try adapter.commit(plan)) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .remoteUnknown)
        }
        XCTAssertEqual(probe.addCount, 1)
        XCTAssertEqual(probe.removeCount, 0)
        let record = try XCTUnwrap(MulticaRecoveryJournal.load(from: recovery))
        XCTAssertEqual(record.phase, "unknown")
        XCTAssertEqual(record.createdServerID, "created-id")
    }

    func testLocalApplyStopsWhenAskKeyAppearsAfterCheck() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-cursor-home-\(UUID().uuidString)", isDirectory: true)
        let support = home.appendingPathComponent("support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: support.appendingPathComponent("cursor", isDirectory: true),
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            brokerSocketPath: support.appendingPathComponent("broker.sock").path,
            signing: .development
        )
        XCTAssertFalse(try adapter.hasConfiguration())
        let config = adapter.userConfigURL
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = Data(#"{"mcpServers":{"askkey":{"command":"askkey"}}}"#.utf8)
        try bytes.write(to: config)
        XCTAssertTrue(try adapter.hasConfiguration())
        let connector = AgentClientConnector(home: home, supportDirectory: support)
        let plan = samplePlan(.cursor)
        XCTAssertThrowsError(try connector.apply(.cursor, plan: plan)) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .planChanged)
        }
        XCTAssertEqual(try Data(contentsOf: config), bytes)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for condition")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

private final class RepairGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func release() async {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }
}

private final class RepairProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var applies = 0
    var checkHandler: (@Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport)?
    var applyHandler: (@Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport)?
    var authenticateHandler: (@MainActor @Sendable () async -> AgentAuthenticationOutcome)?
    var sessionValid = true

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
            authenticate: { await self.authenticateHandler?() ?? .confirmed },
            revalidateWriteSession: { self.sessionValid }
        )
    }
}

private func samplePlan(_ client: AgentClient) -> AgentOnboardingPlan {
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
        activeAgentFingerprint: client == .multica ? "agent-1,agent-2" : ""
    )
}
