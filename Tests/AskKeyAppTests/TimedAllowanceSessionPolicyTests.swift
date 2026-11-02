import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceSessionPolicyTests: XCTestCase {
    func testEndingEventsRevokeWithoutPolicyReadWhenEitherLocalFlagIsOn() throws {
        for (active, sleeping) in [(false, false), (true, true)] {
            for memoryOn in [false, true] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                try vault.updateEndTimedAllowancesOnLock(memoryOn, using: .allow)
                let approvals = vault.approvalRequests
                // Exercise both halves of the save/apply window independently.
                approvals.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
                    timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: !memoryOn)
                approvals.configureAuthentication { _ in true }
                let timed = try submit(approvals, credential: "timed")
                _ = try approvals.decide(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
                let reads = library.keys.policyReads
                library.keys.loadFailure = VaultError.managementAuthenticationRequired
                vault.updateTimedAllowanceSession(active: active, ending: true, sleeping: sleeping ? true : nil)
                XCTAssertEqual(library.keys.policyReads, reads, "Revocation must not wait for any policy read")
                XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
                XCTAssertEqual(try approvals.status(requestID: timed.requestID, capability: timed.capability), .cancelled)
            }
        }
    }

    func testOffInactiveEventsReadOnceWithoutInvalidatingDecisionAndResumeNeverReadsPolicy() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        let screen = TimedAllowanceTestNotificationCenter()
        let workspace = TimedAllowanceTestNotificationCenter()
        let reads = library.keys.policyReads
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        XCTAssertEqual(library.keys.policyReads, reads, "Initial active session must not read Keychain")
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        let inactiveEvents = [Notification.Name("com.apple.screenIsLocked"), NSWorkspace.willSleepNotification,
                              NSWorkspace.sessionDidResignActiveNotification]
        for (index, event) in inactiveEvents.enumerated() {
            let pending = try submit(approvals, credential: UUID().uuidString)
            XCTAssertEqual(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120), revalidate: {
                    (index == 0 ? screen : workspace).post(name: event, object: nil)
                }).state, .approved, "An off event must not advance the generation")
            XCTAssertEqual(library.keys.policyReads, reads + index + 1)
        }
        let afterInactive = library.keys.policyReads
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(library.keys.policyReads, afterInactive)
    }

    func testLockAndSleepCancelUnconsumedTimedEntryAndRejectPreparedTimedDeliveryOnlyWhenEnabled() throws {
        for enabled in [false, true] {
            for sleep in [false, true] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                let vault = library.vault
                try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                try vault.beginManagementSession(using: .allow)
                _ = try vault.createTextCredential(.init(name: "ASK", value: "synthetic", permission: .ask), using: .allow)
                let approvals = vault.approvalRequests
                approvals.configureAuthentication { _ in true }
                let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["ASK"])
                guard case let .approvalRequired(tickets) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                    return XCTFail("Expected Ask approval")
                }
                let timed = try XCTUnwrap(tickets.first)
                _ = try vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
                guard case let .resolved(_, _, optionalLease) = try vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                    return XCTFail("Expected prepared timed delivery")
                }
                let lease = try XCTUnwrap(optionalLease)
                defer { lease.finish(); lease.cleanup() }
                let unconsumed = try submit(approvals, credential: "unconsumed")
                _ = try vault.decideAgentApproval(requestID: unconsumed.requestID, capability: unconsumed.capability, decision: .timedAllow(duration: 120))
                let screen = TimedAllowanceTestNotificationCenter()
                let workspace = TimedAllowanceTestNotificationCenter()
                let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                    screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
                defer { withExtendedLifetime(observer) {} }
                (sleep ? workspace : screen).post(
                    name: sleep ? NSWorkspace.willSleepNotification : .init("com.apple.screenIsLocked"), object: nil)
                XCTAssertEqual(try approvals.status(requestID: unconsumed.requestID, capability: unconsumed.capability),
                    enabled ? .cancelled : .approved)
                var spawned = false
                let spawn = { try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { spawned = true }) }
                if enabled {
                    XCTAssertThrowsError(try spawn())
                    XCTAssertFalse(spawned)
                } else {
                    try spawn()
                    XCTAssertTrue(spawned)
                }
            }
        }
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String) throws -> BrokerApprovalTicket {
        try approvals.submit(.init(operationID: UUID().uuidString, credentialID: credential, targetID: credential,
            operation: .read, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}
