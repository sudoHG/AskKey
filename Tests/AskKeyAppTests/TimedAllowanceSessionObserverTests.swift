import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceSessionObserverTests: XCTestCase {
    func testLockAndSleepRevokeAllTimedAllowancesOnlyWhenEnabledWithoutChangingOtherRequests() throws {
        for enabled in [false, true] {
            for event in [Notification.Name("com.apple.screenIsLocked"), NSWorkspace.willSleepNotification] {
                let library = try AgentAccessPolicyTestLibrary()
                defer { try? library.close() }
                try library.vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
                let approvals = library.vault.approvalRequests
                approvals.configureAuthentication { _ in true }
                for credential in ["timed-1", "timed-2"] {
                    let ticket = try submit(approvals, credential: credential)
                    _ = try approvals.decide(requestID: ticket.requestID, capability: ticket.capability,
                                             decision: .timedAllow(duration: 120))
                    XCTAssertNotNil(approvals.timedAllowanceDeadline(credentialID: credential))
                }
                let pendingRead = try submit(approvals, credential: "pending-read")
                let pendingWrite = try submit(approvals, credential: "pending-write", operation: .modify)
                let once = try submit(approvals, credential: "once")
                let write = try submit(approvals, credential: "write", operation: .modify)
                for ticket in [once, write] {
                    _ = try approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
                }
                let screen = NotificationCenter()
                let workspace = NotificationCenter()
                let vault = library.vault
                let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
                    screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
                withExtendedLifetime(observer) {
                    (event == NSWorkspace.willSleepNotification ? workspace : screen).post(name: event, object: nil)
                }
                for credential in ["timed-1", "timed-2"] {
                    XCTAssertEqual(approvals.timedAllowanceDeadline(credentialID: credential) == nil, enabled)
                }
                for ticket in [pendingRead, pendingWrite] {
                    XCTAssertEqual(try approvals.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
                }
                for ticket in [once, write] {
                    XCTAssertEqual(try approvals.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
                }
                XCTAssertFalse(try vault.isAgentAccessPaused())
            }
        }
    }

    func testEachEventReadsTheCurrentSettingAndUnlockOrWakeDoesNotRevoke() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
        let vault = library.vault
        let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3) })
        defer { withExtendedLifetime(observer) {} }
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        for enabled in [true, false, true] {
            screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            try vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
            let credentialID = UUID().uuidString
            let ticket = try submit(approvals, credential: credentialID)
            _ = try approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
            screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
            workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertNotNil(approvals.timedAllowanceDeadline(credentialID: credentialID))
            screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
            XCTAssertEqual(approvals.timedAllowanceDeadline(credentialID: credentialID) == nil, enabled)
        }
    }

    func testUnreadablePolicyDoesNotUndoVerifiedOptInOrCancelPending() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        vault.approvalRequests.configureAuthentication { _ in true }
        let timed = try submit(vault.approvalRequests, credential: "timed")
        _ = try vault.approvalRequests.decide(requestID: timed.requestID, capability: timed.capability,
                                             decision: .timedAllow(duration: 120))
        let pending = try submit(vault.approvalRequests, credential: "pending")
        library.keys.loadFailure = VaultError.managementAuthenticationRequired
        vault.updateTimedAllowanceSession(active: false)
        XCTAssertNil(vault.approvalRequests.timedAllowanceDeadline(credentialID: "timed"))
        XCTAssertEqual(try vault.approvalRequests.status(requestID: pending.requestID, capability: pending.capability), .pending)
        XCTAssertFalse(try vault.isAgentAccessPaused())
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String,
                        operation: BrokerApprovalOperation = .read) throws -> BrokerApprovalTicket {
        try approvals.submit(.init(operationID: UUID().uuidString, credentialID: credential, targetID: credential,
            operation: operation, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}
