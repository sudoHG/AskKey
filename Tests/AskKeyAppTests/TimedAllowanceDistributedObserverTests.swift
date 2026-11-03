import AppKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceDistributedObserverTests: XCTestCase {
    func testDistributedSelectorsUseImmediateDeliveryAndHandleLockAndUnlock() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let center = RecordingDistributedCenter()
        let observer = SynchronousTimedAllowanceSessionObserver(screenNotifications: center, workspaceNotifications: .init(),
            screenState: { .unlocked }, updateSession: { vault.updateTimedAllowanceSession(active: $0, ending: $1, suspended: $2, sleeping: $3, sleepOffsetUpperBound: $4) })
        defer { withExtendedLifetime(observer) {} }
        XCTAssertEqual(Set(center.registrations.map(\.name)),
            Set([Notification.Name("com.apple.screenIsLocked"), .init("com.apple.screenIsUnlocked")]))
        XCTAssertTrue(center.registrations.allSatisfy { $0.behavior == .deliverImmediately })
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        let first = try submit(approvals, credential: "timed")
        _ = try vault.decideAgentApproval(requestID: first.requestID, capability: first.capability, decision: .timedAllow(duration: 120))
        XCTAssertNotNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
        center.deliver(.init("com.apple.screenIsLocked"))
        timedAllowanceSessionTestQueue.sync {}
        XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "timed"))
        XCTAssertEqual(try approvals.status(requestID: first.requestID, capability: first.capability), .cancelled)
        center.deliver(.init("com.apple.screenIsUnlocked"))
        timedAllowanceSessionTestQueue.sync {}
        let fresh = try submit(approvals)
        XCTAssertEqual(try vault.decideAgentApproval(requestID: fresh.requestID, capability: fresh.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
    }

    private func submit(_ approvals: BrokerApprovalStateMachine, credential: String = UUID().uuidString) throws -> BrokerApprovalTicket {
        let id = UUID().uuidString
        return try approvals.submit(.init(operationID: id, credentialID: credential, targetID: credential, operation: .read,
            payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}

/// Records registrations without subscribing to or posting any system event.
private final class RecordingDistributedCenter: DistributedNotificationCenter, @unchecked Sendable {
    struct Registration {
        weak var target: NSObject?
        let selector: Selector
        let name: Notification.Name
        let behavior: DistributedNotificationCenter.SuspensionBehavior
    }
    var registrations: [Registration] = []

    override func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?, object: String?,
                              suspensionBehavior: DistributedNotificationCenter.SuspensionBehavior) {
        guard let target = observer as? NSObject, let name else { return }
        registrations.append(.init(target: target, selector: selector, name: name, behavior: suspensionBehavior))
    }

    override func removeObserver(_ observer: Any) {
        registrations.removeAll { $0.target === observer as AnyObject }
    }

    func deliver(_ name: Notification.Name) {
        for registration in registrations where registration.name == name {
            _ = registration.target?.perform(registration.selector, with: Notification(name: name))
        }
    }
}
