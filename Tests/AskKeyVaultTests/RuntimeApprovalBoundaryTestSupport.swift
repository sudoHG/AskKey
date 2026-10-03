import Darwin
import Dispatch
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

class RuntimeApprovalBoundaryTestSupport: XCTestCase {
    func assertRejectedBeforeSpawn(
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
    func assertRejectedAndClean(
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
    func assertHookFinished(
        _ hook: ApprovalBoundaryHook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(hook.wait(), "boundary worker must finish", file: file, line: line)
        XCTAssertEqual(hook.fireCount, 1, file: file, line: line)
        XCTAssertNil(hook.failure, "a fixture timeout/error must not masquerade as authorization rejection",
                     file: file, line: line)
    }
    func makeHarness(shape: ApprovalDeliveryShape) throws -> ApprovalBoundaryHarness {
        let harness = try ApprovalBoundaryHarness(shape: shape)
        addTeardownBlock {
            guard harness.registrationHook.wait() else { return }
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        return harness
    }
    enum ApprovalDeliveryShape: String, CaseIterable, Sendable {
        case text, file, mixed, mixedAllowedFile
        var includesText: Bool { self != .file }
        var includesFile: Bool { self != .text }
        var expectedKinds: Set<String> {
            Set((includesText ? ["text"] : []) + (includesFile ? ["file"] : []))
        }
    }
    enum ApprovalBoundaryEvent: String, CaseIterable, Sendable {
        case revoke, timedExpiry, onceExpiry
    }
    enum ApprovalBoundaryTestError: Error {
        case timeout(String)
        case missingApproval
        case invalidFixtureState(String)
        case filesSurvivedApprovalInvalidation
    }
    final class ApprovalBoundaryClock: @unchecked Sendable {
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
    final class ApprovalBoundaryFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
        func set() { lock.lock(); stored = true; lock.unlock() }
    }
    final class ApprovalBoundaryHook: @unchecked Sendable {
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
    final class ApprovalBoundaryHarness: @unchecked Sendable {
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
    final class ApprovalBoundaryFailingRemoval: @unchecked Sendable {
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
    final class ApprovalBoundaryDeadline: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date.distantPast
        var value: Date { lock.lock(); defer { lock.unlock() }; return date }
        func set(_ date: Date) { lock.lock(); self.date = date; lock.unlock() }
    }
    final class ApprovalBoundaryRuntimeResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<BrokerTextRunResult, Error>?
        var value: Result<BrokerTextRunResult, Error>? { lock.lock(); defer { lock.unlock() }; return result }
        func store(_ result: Result<BrokerTextRunResult, Error>) { lock.lock(); self.result = result; lock.unlock() }
    }
    final class ApprovalBoundaryDelayedRemoval: @unchecked Sendable {
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
    final class ApprovalBoundaryCleanupSchedule: @unchecked Sendable {
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
}
