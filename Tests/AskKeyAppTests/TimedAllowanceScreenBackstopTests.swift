import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceScreenBackstopTests: XCTestCase {
    func testMissingLockNotificationBlocksCachedReadsAndPreparedTimedDeliveryOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            for blocked in [AgentApprovalScreenState.locked, .unknown] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                let probe = ScreenProbe(.unlocked)
                let approvals = vault.approvalRequests
                approvals.configureTimedAllowanceScreenState { probe.unlocked() }
                try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                approvals.configureAuthentication { _ in true }
                try vault.beginManagementSession(using: .allow)
                for (name, permission) in [("TIMED", CredentialPermission.ask), ("ALLOW", .allowed)] {
                    _ = try vault.createTextCredential(.init(name: name, value: "synthetic", permission: permission), using: .allow)
                }
                let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["TIMED"])
                guard case let .approvalRequired(tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                    return XCTFail("Expected Ask approval")
                }
                let timed = try XCTUnwrap(tickets.first)
                _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
                guard case let .resolved(_, _, optionalTimedLease) = try vault.brokerTextCredentials(for: request, cancellation: .init()),
                      case let .resolved(_, _, optionalAllowLease) = try vault.brokerTextCredentials(
                        for: .init(command: ["/usr/bin/true"], credentialNames: ["ALLOW"]), cancellation: .init()) else {
                    return XCTFail("Expected prepared deliveries")
                }
                let timedLease = try XCTUnwrap(optionalTimedLease)
                let allowLease = try XCTUnwrap(optionalAllowLease)
                defer { timedLease.finish(); timedLease.cleanup(); allowLease.finish(); allowLease.cleanup() }
                let cached = try submit(approvals, credential: "cached")
                _ = try approvals.decide(requestID: cached.requestID, capability: cached.capability, decision: .timedAllow(duration: 120))
                let onceRequest = BrokerApprovalOperationRequest(operationID: UUID().uuidString,
                    credentialID: "once", targetID: "once", operation: .read, payloadDigest: String(repeating: "a", count: 64))
                let once = try approvals.submit(onceRequest, trustedCredentialDeadline: .none)
                _ = try approvals.decide(requestID: once.requestID, capability: once.capability, decision: .once)
                probe.set(blocked) // No lock notification is delivered.
                let next = try submit(approvals, credential: "cached")
                XCTAssertEqual(next.state, enabled ? .pending : .approved)
                XCTAssertEqual(try approvals.status(requestID: cached.requestID, capability: cached.capability), enabled ? .cancelled : .approved)
                if enabled {
                    XCTAssertThrowsError(try timedLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
                    XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "cached"))
                } else {
                    try timedLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
                    XCTAssertEqual(probe.reads, 0, "The setting-off path must never consult the live provider")
                }
                try allowLease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
                XCTAssertEqual(try approvals.consume(requestID: once.requestID, capability: once.capability, operationRequest: onceRequest), .consumed)
                let write = try submit(approvals, credential: "write", operation: .modify)
                XCTAssertEqual(try vault.decideAgentApproval(requestID: write.requestID, capability: write.capability, decision: .once).state, .approved)
                probe.set(.unlocked)
                XCTAssertEqual(try submit(approvals, credential: "cached").state, enabled ? .pending : .approved)
                if !enabled { XCTAssertEqual(probe.reads, 0) }
            }
        }
    }

    func testLiveScreenBackstopRejectsFinalTimedGrantWithoutNotificationAndPreservesPending() throws {
        for blocked in [AgentApprovalScreenState.locked, .unknown] {
            let library = try AgentAccessPolicyTestLibrary()
            defer { try? library.close() }
            let vault = library.vault
            try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            let probe = ScreenProbe(.unlocked)
            let approvals = vault.approvalRequests
            approvals.configureTimedAllowanceScreenState { probe.unlocked() }
            approvals.configureAuthentication { _ in true }
            let pending = try submit(approvals, credential: "pending")
            XCTAssertThrowsError(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120), revalidate: { probe.set(blocked) })) {
                XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
            }
            XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "pending"))
            XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
            probe.set(.unlocked)
            XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)).state, .approved)
        }
    }

    func testPreparedTimedFileDeliveryChecksLiveScreenAtSpawnWithoutAnotherBrokerMutation() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let probe = ScreenProbe(.unlocked)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { probe.unlocked() }
        approvals.configureAuthentication { _ in true }
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createFileCredential(.init(name: "FILE",
            snapshot: .init(originalFilename: "synthetic.txt", bytes: Data("synthetic".utf8)),
            environmentVariable: "FILE_PATH", permission: .ask), using: .allow)
        let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["FILE"])
        guard case let .approvalRequired(tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected Ask approval")
        }
        let timed = try XCTUnwrap(tickets.first)
        _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
        guard case let .resolved(credentials, _, optionalLease) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected prepared file delivery")
        }
        let lease = try XCTUnwrap(optionalLease)
        defer { lease.finish(); lease.cleanup() }
        let path = try XCTUnwrap(credentials.first?.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        probe.set(.locked)
        // No notification, status query, submission or other Broker mutation
        // can revoke this lease before the actual final-spawn check.
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        probe.set(.unlocked)
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Revoked authority cannot revive") }))
    }

    func testFreshLiveScreenStateRecoversStaleUnknownWithoutUnlockNotification() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let probe = ScreenProbe(.unknown)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { probe.unlocked() }
        let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: .init(),
            screenState: { probe.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
        defer { withExtendedLifetime(observer) {} }
        approvals.configureAuthentication { _ in true }
        probe.set(.unlocked)
        let pending = try submit(approvals, credential: "pending")
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testSleepWithoutLockOrDidWakeAllowsFreshTimedGrantButNeverRevivesRevokedAllowance() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { true }
        approvals.configureAuthentication { _ in true }
        let workspace = NotificationCenter()
        let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
        defer { withExtendedLifetime(observer) {} }
        let previous = try submit(approvals, credential: "timed")
        _ = try vault.decideAgentApproval(requestID: previous.requestID, capability: previous.capability,
            decision: .timedAllow(duration: 120))
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        // The console is unlocked after sleep without a password. Deliver no
        // wake, unlock or become-active event before the next live refresh.
        let fresh = try submit(approvals, credential: "timed")
        XCTAssertEqual(fresh.state, .pending)
        XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
        XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
        XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
        XCTAssertEqual(try approvals.status(requestID: previous.requestID, capability: previous.capability), .cancelled)
    }

    func testLiveUnlockedCannotOverrideInactiveSessionUntilBecomeActive() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        approvals.configureTimedAllowanceScreenState { true }
        approvals.configureAuthentication { _ in true }
        let workspace = NotificationCenter()
        let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
        defer { withExtendedLifetime(observer) {} }
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        let pending = try submit(approvals, credential: "inactive-session")
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String,
                        operation: BrokerApprovalOperation = .read) throws -> BrokerApprovalTicket {
        try approvals.submit(.init(operationID: UUID().uuidString, credentialID: credential, targetID: credential,
            operation: operation, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}

private final class ScreenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state: AgentApprovalScreenState
    private var count = 0
    init(_ state: AgentApprovalScreenState) { self.state = state }
    var current: AgentApprovalScreenState { lock.lock(); defer { lock.unlock() }; return state }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ state: AgentApprovalScreenState) { lock.lock(); defer { lock.unlock() }; self.state = state }
    func unlocked() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return state == .unlocked }
}
