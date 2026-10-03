import Darwin
import Dispatch
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class RuntimeApprovalBoundaryTests: XCTestCase {
    func testValidConsumedApprovalsDeliverTheWholeRequestedSetOnce() throws {
        for shape in ApprovalDeliveryShape.allCases {
            for once in [false, true] {
                let harness = try makeHarness(shape: shape)
                let runtime = harness.runtime()
                try harness.approve(request: harness.request, runtime: runtime, once: once)
                XCTAssertEqual(try harness.run(runtime), .exited(0), "\(shape), once=\(once)")
                XCTAssertEqual(try harness.run(runtime), .exited(0), "retransmission must reuse its result")
                XCTAssertEqual(harness.targetStarts, 1)
                XCTAssertEqual(harness.deliveredKinds, shape.expectedKinds)
                XCTAssertTrue(harness.payloadFiles.isEmpty)
            }
        }
    }

    func testRevocationAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .revoke)
    }

    func testTimedExpiryAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .timedExpiry)
    }

    func testOnceExpiryAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .onceExpiry)
    }

    func testNewTimedApprovalCannotReviveARevokedOrExpiredConsumedOperation() throws {
        for event in [ApprovalBoundaryEvent.revoke, .timedExpiry] {
            try assertRejectedBeforeSpawn(event: event, grantAgain: true)
        }
    }

    func testRevocationOrExpiryBeforeFileRegistrationPreventsTheWholeTargetAndCleansUp() throws {
        for shape in [ApprovalDeliveryShape.file, .mixed] {
            for event in ApprovalBoundaryEvent.allCases {
                let harness = try makeHarness(shape: shape)
                let runtime = harness.runtime()
                try harness.approve(request: harness.request, runtime: runtime, once: event == .onceExpiry)
                harness.registrationHook.install {
                    try harness.invalidateConsumedApproval(event)
                }
                assertRejectedAndClean(harness, runtime: runtime, hook: harness.registrationHook,
                                       message: "\(shape), registration, \(event)")
            }
        }
    }

    func testRevocationCannotCompleteInsideTheFinalAuthorizedSpawn() throws {
        let harness = try makeHarness(shape: .mixed)
        let attempted = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let completed = ApprovalBoundaryFlag()
        let runtime = harness.runtime(afterAuthorization: {
            DispatchQueue.global().async {
                attempted.signal()
                _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
                completed.set()
                finished.signal()
            }
            guard attempted.wait(timeout: .now() + 2) == .success else {
                throw ApprovalBoundaryTestError.timeout("revocation worker did not start")
            }
            // The target owns the final authorization boundary. Revocation must
            // serialize after spawn, rather than finish between check and spawn.
            XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        })
        try harness.approve(request: harness.request, runtime: runtime)
        let result = Result { try harness.run(runtime) }
        let workerFinished = completed.value || finished.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(workerFinished, "release all spawn locks even when spawning fails")
        XCTAssertEqual(try result.get(), .exited(0))
        XCTAssertEqual(harness.targetStarts, 1)
        XCTAssertTrue(harness.payloadFiles.isEmpty)
    }

    func testAlreadySpawnedTargetsMayFinishButRevocationAndApprovalExpiryCleanFiles() throws {
        for shape in ApprovalDeliveryShape.allCases {
            for event in ApprovalBoundaryEvent.allCases {
                let harness = try makeHarness(shape: shape)
                let afterSpawn = ApprovalBoundaryHook()
                let runtime = harness.runtime(afterSpawn: { try afterSpawn.fire() })
                try harness.approve(request: harness.request, runtime: runtime, once: event == .onceExpiry)
                afterSpawn.install {
                    try harness.invalidateConsumedApproval(event)
                    // Runtime's final cleanup has not run. The file TTL is 300 s;
                    // logical approval expiry (30/120 s) must clean it independently.
                    guard harness.payloadFiles.isEmpty else {
                        throw ApprovalBoundaryTestError.filesSurvivedApprovalInvalidation
                    }
                }
                XCTAssertEqual(try harness.run(runtime), .exited(0), "\(shape), \(event)")
                assertHookFinished(afterSpawn)
                XCTAssertEqual(harness.targetStarts, 1)
                XCTAssertTrue(harness.payloadFiles.isEmpty)
            }
        }
    }

    func testRejectedRuntimeReportsFailedFileRemovalAndRetriesWithoutStartingTheTarget() throws {
        let removal = ApprovalBoundaryFailingRemoval()
        let harness = try ApprovalBoundaryHarness(shape: .file, cleanupRetryDelay: 60,
                                                 removeItem: { try removal.remove($0) })
        addTeardownBlock {
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        let hook = ApprovalBoundaryHook()
        let sawFailure = ApprovalBoundaryFlag()
        let runtime = harness.runtime(beforeSpawn: { try hook.fire() })
        try harness.approve(request: harness.request, runtime: runtime)
        hook.install {
            try harness.invalidateConsumedApproval(.revoke)
            guard harness.manager.cleanupFailures.count == 1,
                  harness.payloadFiles.count == 1 else {
                throw ApprovalBoundaryTestError.invalidFixtureState("failed deletion must remain visible")
            }
            sawFailure.set()
        }
        assertRejectedAndClean(harness, runtime: runtime, hook: hook, message: "failed revoke cleanup")
        XCTAssertTrue(sawFailure.value)
        XCTAssertGreaterThanOrEqual(removal.attempts, 2)
        XCTAssertTrue(harness.manager.cleanupFailures.isEmpty)
    }

    func testOriginalApprovalDeadlineIsCheckedAgainAtTheActualSystemSpawn() throws {
        let harness = try ApprovalBoundaryHarness(shape: .text, useLiveApprovalClock: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        let deadline = ApprovalBoundaryDeadline()
        let reachedSystemBoundary = ApprovalBoundaryFlag()
        let runtime = harness.runtime(beforeSystemSpawn: {
            reachedSystemBoundary.set()
            let remaining = deadline.value.timeIntervalSinceNow
            guard remaining > 0, remaining < 2 else {
                throw ApprovalBoundaryTestError.invalidFixtureState("deadline must still be future at the system boundary")
            }
            // Deliberately real time: the C layer reads CLOCK_REALTIME. Injected
            // state-machine time cannot prove this final deadline propagation.
            Thread.sleep(forTimeInterval: remaining + 0.02)
        })
        try harness.approve(request: harness.request, runtime: runtime, timedDuration: 1)
        deadline.set(try XCTUnwrap(harness.approvals.timedAllowanceDeadline(
            credentialID: harness.revokedCredentialID
        )))
        XCTAssertThrowsError(try harness.run(runtime)) {
            XCTAssertEqual($0 as? BrokerProviderError, .requestRejected)
        }
        XCTAssertTrue(reachedSystemBoundary.value)
        XCTAssertEqual(harness.targetStarts, 0)
    }

    func testFailureAtEitherFinalSpawnHookReleasesApprovalAndVaultLocks() throws {
        for beforeSystemCall in [false, true] {
            let harness = try makeHarness(shape: .mixed)
            let fail: BrokerTextRuntime.SpawnBoundaryHook = { throw BrokerTextRuntimeError.spawnFailed }
            let noop: BrokerTextRuntime.SpawnBoundaryHook = {}
            let runtime = harness.runtime(afterAuthorization: beforeSystemCall ? noop : fail,
                                          beforeSystemSpawn: beforeSystemCall ? fail : noop)
            try harness.approve(request: harness.request, runtime: runtime)
            XCTAssertThrowsError(try harness.run(runtime))
            let followup = ApprovalBoundaryHook()
            followup.install {
                _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
                try harness.vault.pauseAgentAccess(using: .allow)
            }
            XCTAssertNoThrow(try followup.fire())
            assertHookFinished(followup)
            XCTAssertEqual(harness.targetStarts, 0)
            XCTAssertTrue(harness.payloadFiles.isEmpty)
        }
    }

    func testDelayedOldFileCleanupCannotDeleteANewlyApprovedDelivery() throws {
        let removal = ApprovalBoundaryDelayedRemoval()
        let harness = try ApprovalBoundaryHarness(shape: .file, removeItem: { try removal.remove($0) })
        let oldReady = DispatchSemaphore(value: 0)
        let resumeOld = DispatchSemaphore(value: 0)
        let oldDone = DispatchGroup()
        let revokeDone = DispatchGroup()
        let oldResult = ApprovalBoundaryRuntimeResult()
        defer {
            resumeOld.signal()
            removal.release.signal()
            _ = oldDone.wait(timeout: .now() + 3)
            _ = revokeDone.wait(timeout: .now() + 3)
        }
        addTeardownBlock {
            guard oldDone.wait(timeout: .now() + 3) == .success,
                  revokeDone.wait(timeout: .now() + 3) == .success else { return }
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        let oldRuntime = harness.runtime(beforeSpawn: {
            oldReady.signal()
            guard resumeOld.wait(timeout: .now() + 3) == .success else {
                throw ApprovalBoundaryTestError.timeout("old runtime was not resumed")
            }
        })
        try harness.approve(request: harness.request, runtime: oldRuntime)
        oldDone.enter()
        DispatchQueue.global().async {
            defer { oldDone.leave() }
            oldResult.store(Result { try harness.run(oldRuntime) })
        }
        guard oldReady.wait(timeout: .now() + 2) == .success else {
            return XCTFail("old runtime did not reach its materialized-file boundary")
        }
        let oldFiles = Set(harness.payloadFiles)
        XCTAssertEqual(oldFiles.count, 1)
        revokeDone.enter()
        DispatchQueue.global().async {
            defer { revokeDone.leave() }
            _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
        }
        guard removal.entered.wait(timeout: .now() + 2) == .success else {
            return XCTFail("old cleanup did not begin")
        }
        try harness.grantNewOperation()
        let fresh = try XCTUnwrap(harness.renewedRequest)
        let freshRuntime = harness.runtime(beforeSpawn: {
            let freshFiles = Set(harness.payloadFiles).subtracting(oldFiles)
            removal.release.signal()
            guard revokeDone.wait(timeout: .now() + 2) == .success, freshFiles.count == 1,
                  freshFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ApprovalBoundaryTestError.invalidFixtureState("old cleanup removed or blocked the new delivery")
            }
        })
        XCTAssertEqual(try harness.run(freshRuntime, request: fresh), .exited(0))
        XCTAssertEqual(harness.deliveredKinds, Set(["file"]))
        resumeOld.signal()
        XCTAssertEqual(oldDone.wait(timeout: .now() + 3), .success)
        guard case .failure(let error) = try XCTUnwrap(oldResult.value) else {
            return XCTFail("the revoked old runtime must be refused")
        }
        XCTAssertEqual(error as? BrokerProviderError, .requestRejected)
        XCTAssertEqual(harness.targetStarts, 1, "only the new authorization may start a target")
        XCTAssertTrue(harness.payloadFiles.isEmpty)
        XCTAssertFalse(removal.timedOut)
    }

    func testSlowMaterializationRejectsAnAlreadyExpiredFileWithoutAnApprovalScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeySlowExpiredFile-\(UUID().uuidString)")
        let clock = ApprovalBoundaryClock()
        let schedule = ApprovalBoundaryCleanupSchedule()
        let manager = try FileDeliveryManager(
            rootURL: root, ttl: 30, now: { clock.now }, schedule: { schedule.record($0, $1) },
            synchronizeFile: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else { return -1 }
                clock.advance(30)
                return 0
            }
        )
        defer { manager.cleanupAll(); try? FileManager.default.removeItem(at: root) }
        var unexpectedlyReturned: FileDelivery?
        XCTAssertThrowsError(unexpectedlyReturned = try manager.materialize(
            credentialID: "allowed-without-approval", bytes: Data("synthetic-file".utf8)
        ))
        withExtendedLifetime(unexpectedlyReturned) {
            XCTAssertTrue(ApprovalBoundaryHarness.payloadFiles(in: root).isEmpty)
        }
    }

    func testSlowMaterializationSchedulesOnlyTheRemainingAbsoluteFileLifetime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeySlowRemainingFile-\(UUID().uuidString)")
        let clock = ApprovalBoundaryClock()
        let start = clock.now
        let schedule = ApprovalBoundaryCleanupSchedule()
        let manager = try FileDeliveryManager(
            rootURL: root, ttl: 30, now: { clock.now }, schedule: { schedule.record($0, $1) },
            synchronizeFile: { descriptor in
                guard Darwin.fsync(descriptor) == 0 else { return -1 }
                clock.advance(10)
                return 0
            }
        )
        defer { manager.cleanupAll(); try? FileManager.default.removeItem(at: root) }
        let delivery = try manager.materialize(
            credentialID: "allowed-without-approval", bytes: Data("synthetic-file".utf8)
        )
        XCTAssertEqual(delivery.expiresAt, start.addingTimeInterval(30))
        XCTAssertEqual(schedule.delays, [20], "fsync must consume, rather than restart, the file lifetime")
        clock.advance(20)
        schedule.fire()
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
    }

    private func assertRejectedBeforeSpawn(
        event: ApprovalBoundaryEvent,
        grantAgain: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for shape in ApprovalDeliveryShape.allCases {
            let harness = try makeHarness(shape: shape)
            let hook = ApprovalBoundaryHook()
            let runtime = harness.runtime(beforeSpawn: { try hook.fire() })
            try harness.approve(request: harness.request, runtime: runtime, once: event == .onceExpiry)
            hook.install {
                try harness.invalidateConsumedApproval(event)
                if grantAgain { try harness.grantNewOperation() }
            }
            assertRejectedAndClean(harness, runtime: runtime, hook: hook,
                                   message: "\(shape), \(event), regrant=\(grantAgain)",
                                   file: file, line: line)
            if grantAgain {
                XCTAssertNotNil(harness.approvals.timedAllowanceDeadline(
                    credentialID: harness.revokedCredentialID
                ), "the new approval exists but must not revive the old consumption", file: file, line: line)
                let fresh = try XCTUnwrap(harness.renewedRequest, file: file, line: line)
                XCTAssertEqual(try harness.run(harness.runtime(), request: fresh), .exited(0), file: file, line: line)
                XCTAssertEqual(harness.targetStarts, 1, "only the newly approved operation may start", file: file, line: line)
                XCTAssertEqual(harness.deliveredKinds, shape.expectedKinds, file: file, line: line)
                XCTAssertTrue(harness.payloadFiles.isEmpty, file: file, line: line)
            }
        }
    }

    private func assertRejectedAndClean(
        _ harness: ApprovalBoundaryHarness,
        runtime: BrokerTextRuntime,
        hook: ApprovalBoundaryHook,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try harness.run(runtime), message, file: file, line: line)
        assertHookFinished(hook, file: file, line: line)
        XCTAssertThrowsError(try harness.run(runtime), "retransmission must retain the refusal: \(message)",
                             file: file, line: line)
        XCTAssertEqual(harness.targetStarts, 0, message, file: file, line: line)
        XCTAssertTrue(harness.payloadFiles.isEmpty, "no materialized file may survive rejection: \(message)",
                      file: file, line: line)
    }

    private func assertHookFinished(
        _ hook: ApprovalBoundaryHook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(hook.wait(), "boundary worker must finish", file: file, line: line)
        XCTAssertEqual(hook.fireCount, 1, file: file, line: line)
        XCTAssertNil(hook.failure, "a fixture timeout/error must not masquerade as authorization rejection",
                     file: file, line: line)
    }

    private func makeHarness(shape: ApprovalDeliveryShape) throws -> ApprovalBoundaryHarness {
        let harness = try ApprovalBoundaryHarness(shape: shape)
        addTeardownBlock {
            guard harness.registrationHook.wait() else { return }
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        return harness
    }
}

private enum ApprovalDeliveryShape: String, CaseIterable, Sendable {
    case text, file, mixed, mixedAllowedFile
    var includesText: Bool { self != .file }
    var includesFile: Bool { self != .text }
    var expectedKinds: Set<String> {
        Set((includesText ? ["text"] : []) + (includesFile ? ["file"] : []))
    }
}

private enum ApprovalBoundaryEvent: String, CaseIterable, Sendable {
    case revoke, timedExpiry, onceExpiry
}

private enum ApprovalBoundaryTestError: Error {
    case timeout(String)
    case missingApproval
    case invalidFixtureState(String)
    case filesSurvivedApprovalInvalidation
}

private final class ApprovalBoundaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    private let live: Bool
    init(live: Bool = false) { self.live = live }
    var now: Date { lock.lock(); defer { lock.unlock() }; return live ? Date() : date }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

private final class ApprovalBoundaryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}

/// A one-shot, instance-owned ordering seam. Work is bounded so an implementation
/// which waits for its own active Vault operation fails instead of hanging XCTest.
private final class ApprovalBoundaryHook: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var action: (@Sendable () throws -> Void)?
    private var count = 0
    private var errorText: String?

    var fireCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return errorText }

    func install(_ action: @escaping @Sendable () throws -> Void) {
        lock.lock(); self.action = action; lock.unlock()
    }

    func fire() throws {
        lock.lock()
        guard let current = action else { lock.unlock(); return }
        action = nil
        count += 1
        lock.unlock()
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            do { try current() }
            catch {
                lock.lock(); errorText = String(describing: error); lock.unlock()
            }
        }
        guard group.wait(timeout: .now() + 2) == .success else {
            lock.lock(); errorText = "boundary action timed out"; lock.unlock()
            throw ApprovalBoundaryTestError.timeout("boundary action")
        }
        if let failure { throw ApprovalBoundaryTestError.invalidFixtureState(failure) }
    }

    func wait() -> Bool { group.wait(timeout: .now() + 3) == .success }
}

private final class ApprovalBoundaryHarness: @unchecked Sendable {
    let root: URL
    let manager: FileDeliveryManager
    let approvals: BrokerApprovalStateMachine
    let registrationHook: ApprovalBoundaryHook
    let clock: ApprovalBoundaryClock
    let vault: Vault
    let request: BrokerTextRunRequest
    let revokedCredentialID: String
    private let approvalCount: Int
    private let deliveryRoot: URL
    private let targetMarker: URL
    private let deliveryMarker: URL
    private var originalTickets: [BrokerApprovalTicket] = []
    private(set) var renewedRequest: BrokerTextRunRequest?

    init(
        shape: ApprovalDeliveryShape,
        useLiveApprovalClock: Bool = false,
        cleanupRetryDelay: TimeInterval = 1,
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyRuntimeApprovalBoundary-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: root) } }
        let deliveryRoot = root.appendingPathComponent("deliveries", isDirectory: true)
        self.deliveryRoot = deliveryRoot
        let targetMarker = root.appendingPathComponent("target-starts.txt")
        self.targetMarker = targetMarker
        let deliveryMarker = root.appendingPathComponent("delivered-kinds.txt")
        self.deliveryMarker = deliveryMarker
        let hook = ApprovalBoundaryHook()
        registrationHook = hook
        let manager = try FileDeliveryManager(rootURL: deliveryRoot, ttl: 300, retryDelay: cleanupRetryDelay,
                                             removeItem: removeItem, synchronizeFile: { descriptor in
            guard Darwin.fsync(descriptor) == 0 else { return -1 }
            do { try hook.fire(); return 0 }
            catch { errno = ETIMEDOUT; return -1 }
        })
        self.manager = manager
        let injectedClock = ApprovalBoundaryClock(live: useLiveApprovalClock)
        clock = injectedClock
        let approvals = BrokerApprovalStateMachine(
            requestTTL: 120,
            clock: { injectedClock.now },
            authenticate: { _ in true }
        )
        self.approvals = approvals
        let vault = Vault(
            store: try VaultStore(path: root.appendingPathComponent("synthetic.db").path),
            key: VaultCrypto.generateKey(),
            now: { injectedClock.now },
            approvalRequests: approvals,
            fileDeliveryManager: manager
        )
        self.vault = vault
        try vault.beginManagementSession(using: .allow)
        var names: [String] = []
        var ids: [String] = []
        if shape.includesText {
            let created = try vault.createTextCredential(
                .init(name: "BOUNDARY_TEXT", value: "synthetic-text", environmentVariable: "TOKEN", permission: .ask),
                using: .allow
            )
            names.append(created.name); ids.append(created.id)
        }
        if shape.includesFile {
            let created = try vault.createFileCredential(
                .init(
                    name: "BOUNDARY_FILE",
                    snapshot: try FileImport.FrozenFile(
                        originalFilename: "synthetic.txt", bytes: Data("synthetic-file\n".utf8)
                    ),
                    environmentVariable: "KEY_FILE",
                    permission: shape == .mixedAllowedFile ? .allowed : .ask
                ),
                using: .allow
            )
            names.append(created.name)
            if shape != .mixedAllowedFile { ids.append(created.id) }
        }
        revokedCredentialID = ids.last!
        approvalCount = ids.count
        // The mixed case uses two independent Ask credentials, exercising batch
        // approval consumption as well as the atomic target's delivery mappings.
        let script = """
        printf 'started\n' >> "$1"
        if [ "${TOKEN-}" = 'synthetic-text' ]; then printf 'text\n' >> "$2"; fi
        if [ -n "${KEY_FILE-}" ] && [ -r "$KEY_FILE" ]; then
            IFS= read -r payload < "$KEY_FILE"
            if [ "$payload" = 'synthetic-file' ]; then printf 'file\n' >> "$2"; fi
        fi
        exit 0
        """
        request = BrokerTextRunRequest(
            command: ["/bin/sh", "-c", script, "boundary", targetMarker.path, deliveryMarker.path],
            credentialNames: names,
            workingDirectory: root.path,
            inheritedEnvironment: [:]
        )
        initialized = true
    }

    var targetStarts: Int {
        ((try? String(contentsOf: targetMarker, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    var deliveredKinds: Set<String> {
        Set(((try? String(contentsOf: deliveryMarker, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))
    }

    var payloadFiles: [URL] {
        Self.payloadFiles(in: deliveryRoot)
    }

    static func payloadFiles(in root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func runtime(
        beforeSpawn: @escaping BrokerTextRuntime.SpawnBoundaryHook = {},
        afterAuthorization: @escaping BrokerTextRuntime.SpawnBoundaryHook = {},
        beforeSystemSpawn: @escaping BrokerTextRuntime.SpawnBoundaryHook = {},
        afterSpawn: @escaping BrokerTextRuntime.SpawnBoundaryHook = {}
    ) -> BrokerTextRuntime {
        BrokerTextRuntime(
            resolveCredentials: { [self] request, cancellation in
                try vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            beforeSpawn: beforeSpawn,
            afterAuthorization: afterAuthorization,
            beforeSystemSpawn: beforeSystemSpawn,
            afterSpawn: afterSpawn
        )
    }

    func approve(request: BrokerTextRunRequest, runtime: BrokerTextRuntime,
                 once: Bool = false, timedDuration: TimeInterval = 30) throws {
        guard case .approvalRequired(_, let tickets) = try runtime.run(request),
              tickets.count == approvalCount else {
            throw ApprovalBoundaryTestError.missingApproval
        }
        originalTickets = tickets
        for ticket in tickets {
            _ = try approvals.decide(
                requestID: ticket.requestID, capability: ticket.capability,
                decision: once ? .once : .timedAllow(duration: timedDuration)
            )
        }
    }

    func run(_ runtime: BrokerTextRuntime, request: BrokerTextRunRequest? = nil) throws -> BrokerTextRunResult {
        let cancellation = BrokerCancellation()
        let timeout = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        return try runtime.run(request ?? self.request, cancellation: cancellation)
    }

    func invalidateConsumedApproval(_ event: ApprovalBoundaryEvent) throws {
        for ticket in originalTickets {
            guard try approvals.status(requestID: ticket.requestID, capability: ticket.capability) == .consumed else {
                throw ApprovalBoundaryTestError.invalidFixtureState("event must occur after batch consumption")
            }
        }
        switch event {
        case .revoke:
            guard approvals.revokeTimedAllowance(credentialID: revokedCredentialID) else {
                throw ApprovalBoundaryTestError.invalidFixtureState("expected an active timed allowance")
            }
        case .timedExpiry:
            clock.advance(30)
        case .onceExpiry:
            clock.advance(120)
        }
        // Existing injected-clock projection drives the expiry sweep without
        // sleeping for either the approval duration or the longer file TTL.
        guard approvals.timedAllowanceDeadline(credentialID: revokedCredentialID) == nil else {
            throw ApprovalBoundaryTestError.invalidFixtureState("allowance must be absent after invalidation")
        }
    }

    func grantNewOperation() throws {
        let freshRequest = BrokerTextRunRequest(
            command: request.command, credentialNames: request.credentialNames,
            workingDirectory: root.path, inheritedEnvironment: [:]
        )
        guard case .approvalRequired(let tickets) = try vault.brokerTextCredentials(
            for: freshRequest, cancellation: BrokerCancellation()
        ), !tickets.isEmpty else {
            throw ApprovalBoundaryTestError.missingApproval
        }
        for ticket in tickets {
            _ = try approvals.decide(
                requestID: ticket.requestID, capability: ticket.capability,
                decision: .timedAllow(duration: 30)
            )
        }
        renewedRequest = freshRequest
    }
}

private final class ApprovalBoundaryFailingRemoval: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    func remove(_ url: URL) throws {
        lock.lock()
        count += 1
        let fail = count == 1
        lock.unlock()
        if fail { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY)) }
        try FileManager.default.removeItem(at: url)
    }
}

private final class ApprovalBoundaryDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date.distantPast
    var value: Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ date: Date) { lock.lock(); self.date = date; lock.unlock() }
}

private final class ApprovalBoundaryRuntimeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<BrokerTextRunResult, Error>?
    var value: Result<BrokerTextRunResult, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    func store(_ result: Result<BrokerTextRunResult, Error>) { lock.lock(); self.result = result; lock.unlock() }
}

private final class ApprovalBoundaryDelayedRemoval: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first = true
    private var failed = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    func remove(_ url: URL) throws {
        lock.lock()
        let delay = first
        first = false
        lock.unlock()
        if delay {
            entered.signal()
            guard release.wait(timeout: .now() + 3) == .success else {
                lock.lock(); failed = true; lock.unlock()
                throw ApprovalBoundaryTestError.timeout("delayed old cleanup")
            }
        }
        try FileManager.default.removeItem(at: url)
    }
}

private final class ApprovalBoundaryCleanupSchedule: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [TimeInterval] = []
    private var actions: [@Sendable () -> Void] = []
    var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recordedDelays }
    func record(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        lock.lock()
        recordedDelays.append(delay)
        actions.append(action)
        lock.unlock()
    }
    func fire() {
        lock.lock()
        let pending = actions
        actions.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }
}
