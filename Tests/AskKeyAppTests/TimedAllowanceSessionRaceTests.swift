import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceSessionRaceTests: XCTestCase {
    func testSessionEndBetweenRevalidationAndFinalMutationRejectsOnlyOptedInTimedDecision() throws {
        for enabled in [false, true] {
            for sleep in [false, true] {
                for resumeBeforeMutation in [false, true] {
                    let library = try AgentAccessPolicyTestLibrary()
                    defer { try? library.close() }
                    let vault = library.vault
                    try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                    try vault.beginManagementSession(using: .allow)
                    _ = try vault.createTextCredential(.init(name: "ALLOW", value: "synthetic", permission: .allowed), using: .allow)
                    guard case let .resolved(_, _, optionalLease) = try vault.brokerTextCredentials(
                        for: .init(command: ["/usr/bin/true"], credentialNames: ["ALLOW"]), cancellation: .init()) else {
                        return XCTFail("Allow must resolve without approval")
                    }
                    let lease = try XCTUnwrap(optionalLease)
                    defer { lease.finish(); lease.cleanup() }
                    let approvals = vault.approvalRequests
                    approvals.configureAuthentication { _ in true }
                    let onceRequest = BrokerApprovalOperationRequest(operationID: UUID().uuidString,
                        credentialID: "once", targetID: "once", operation: .read, payloadDigest: String(repeating: "a", count: 64))
                    let once = try approvals.submit(onceRequest, trustedCredentialDeadline: .none)
                    let write = try submit(approvals, credential: "write", operation: .modify)
                    for ticket in [once, write] {
                        _ = try vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
                    }
                    let pendingWrite = try submit(approvals, credential: "pending-write", operation: .modify)
                    let timed = try submit(approvals, credential: "timed")
                    let screen = NotificationCenter()
                    let workspace = NotificationCenter()
                    let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                        screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
                    defer { withExtendedLifetime(observer) {} }
                    let decide = {
                        try approvals.decide(requestID: timed.requestID, capability: timed.capability,
                            decision: .timedAllow(duration: 120), revalidate: {
                                // Authentication has succeeded. Complete the real policy check,
                                // then suspend the decision at the last existing seam before mutation.
                                try vault.agentAccessGate.beginSpawnAuthorization(validating: vault.revalidateAgentAccessPolicy)
                                vault.agentAccessGate.endSpawnAuthorization()
                                XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                                (sleep ? workspace : screen).post(
                                    name: sleep ? NSWorkspace.willSleepNotification : .init("com.apple.screenIsLocked"), object: nil)
                                XCTAssertEqual(try approvals.status(requestID: timed.requestID, capability: timed.capability), .pending)
                                if resumeBeforeMutation {
                                    (sleep ? workspace : screen).post(
                                        name: sleep ? NSWorkspace.didWakeNotification : .init("com.apple.screenIsUnlocked"), object: nil)
                                }
                            })
                    }
                    if enabled {
                        XCTAssertThrowsError(try decide()) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                        XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                        XCTAssertEqual(try approvals.status(requestID: timed.requestID, capability: timed.capability), .pending)
                        let following = try submit(approvals, credential: "timed")
                        XCTAssertEqual(following.state, .pending, "No allowance may serve a later read")
                    } else {
                        XCTAssertEqual(try decide().state, .approved)
                        XCTAssertNotNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                    }
                    for ticket in [once, write] {
                        XCTAssertEqual(try approvals.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
                    }
                    XCTAssertEqual(try approvals.consume(requestID: once.requestID, capability: once.capability,
                        operationRequest: onceRequest), .consumed)
                    XCTAssertEqual(try approvals.status(requestID: pendingWrite.requestID, capability: pendingWrite.capability), .pending)
                    _ = try vault.decideAgentApproval(requestID: pendingWrite.requestID, capability: pendingWrite.capability, decision: .once)
                    var spawned = false
                    try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { spawned = true })
                    XCTAssertTrue(spawned)
                    XCTAssertFalse(try vault.isAgentAccessPaused())
                }
            }
        }
    }

    func testLockedOrUnknownLaunchBlocksTimedGrantsOnlyWhenEnabledAndUnlockAllowsFreshDecision() throws {
        for enabled in [false, true] {
            for initialState in [AgentApprovalScreenState.locked, .unknown, .unlocked] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                let screen = NotificationCenter()
                let screenState = TimedAllowanceTestScreenState(initialState)
                let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: .init(),
                    screenState: { screenState.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
                defer { withExtendedLifetime(observer) {} }
                let approvals = vault.approvalRequests
                approvals.configureAuthentication { _ in true }
                let timed = try submit(approvals, credential: "timed")
                if enabled && initialState != .unlocked {
                    XCTAssertThrowsError(try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability,
                        decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                    XCTAssertEqual(try approvals.status(requestID: timed.requestID, capability: timed.capability), .pending)
                } else {
                    _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
                    XCTAssertNotNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                }
                screenState.set(.unlocked)
                screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
                let fresh = try submit(approvals, credential: "fresh")
                XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                    decision: .timedAllow(duration: 120)).state, .approved)
            }
        }
    }

    func testEnablingWhileLockedRevokesAndBlocksButDisablingRestoresExistingBehavior() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: .init(),
            screenState: { .locked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
        defer { withExtendedLifetime(observer) {} }
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        let first = try submit(approvals, credential: "first")
        _ = try vault.decideAgentApproval(requestID: first.requestID, capability: first.capability, decision: .timedAllow(duration: 120))
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "first"))
        let pending = try submit(approvals, credential: "pending")
        XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
        try vault.updateEndTimedAllowancesOnLock(false, using: .allow)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testUnlockAndWakeRecheckLockedScreenBeforeAllowingTimedGrants() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
        let screenState = TimedAllowanceTestScreenState(.locked)
        let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { screenState.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
        defer { withExtendedLifetime(observer) {} }
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        let pending = try submit(approvals, credential: "pending")
        for wake in [false, true] {
            if wake { workspace.post(name: NSWorkspace.didWakeNotification, object: nil) }
            XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
            XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "pending"))
            XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
        }
        screenState.set(.unlocked)
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testUnlockRecoversFromMissedWakeNotification() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
        let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
        defer { withExtendedLifetime(observer) {} }
        vault.approvalRequests.configureAuthentication { _ in true }
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        let pending = try submit(vault.approvalRequests, credential: "pending")
        XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    func testFastUserSwitchEndsAllowancesOnlyWhenEnabledAndReturnRechecksScreen() throws {
        for enabled in [false, true] {
            let library = try AgentAccessPolicyTestLibrary()
            defer { try? library.close() }
            let vault = library.vault
            try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
            let workspace = NotificationCenter()
            let screenState = TimedAllowanceTestScreenState(.unlocked)
            let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
                screenState: { screenState.current }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2) })
            defer { withExtendedLifetime(observer) {} }
            let approvals = vault.approvalRequests
            approvals.configureAuthentication { _ in true }
            let allowed = try submit(approvals, credential: "allowed")
            _ = try vault.decideAgentApproval(requestID: allowed.requestID, capability: allowed.capability, decision: .timedAllow(duration: 120))
            workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            XCTAssertEqual(approvals.timedAllowanceDeadline(credentialID: "allowed") == nil, enabled)
            XCTAssertEqual(try approvals.status(requestID: allowed.requestID, capability: allowed.capability), enabled ? .cancelled : .approved)
            for returning in [false, true] {
                if returning {
                    screenState.set(.locked)
                    workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
                }
                let pending = try submit(approvals, credential: UUID().uuidString)
                if enabled {
                    XCTAssertThrowsError(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                        decision: .timedAllow(duration: 120))) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertEqual(try approvals.status(requestID: pending.requestID, capability: pending.capability), .pending)
                } else {
                    XCTAssertEqual(try vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability,
                        decision: .timedAllow(duration: 120)).state, .approved)
                }
            }
            screenState.set(.unlocked)
            workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            let fresh = try submit(approvals, credential: "fresh")
            XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
                decision: .timedAllow(duration: 120)).state, .approved)
        }
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String,
                        operation: BrokerApprovalOperation = .read) throws -> BrokerApprovalTicket {
        try approvals.submit(.init(operationID: UUID().uuidString, credentialID: credential, targetID: credential,
            operation: operation, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}

private final class TimedAllowanceTestScreenState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentApprovalScreenState

    init(_ value: AgentApprovalScreenState) { self.value = value }

    var current: AgentApprovalScreenState {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: AgentApprovalScreenState) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
