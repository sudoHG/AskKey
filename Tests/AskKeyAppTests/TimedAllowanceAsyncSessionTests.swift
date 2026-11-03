import AppKit
import XCTest
@testable import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class TimedAllowanceAsyncSessionTests: XCTestCase {
    func testBlockedVaultCallbackDoesNotBlockPostingAndEventsKeepReceiptOrder() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        approvals.configureTimedAllowanceScreenState { true }
        let operation = request("runtime")
        let timed = try approvals.submit(operation, trustedCredentialDeadline: .none)
        _ = try approvals.decide(requestID: timed.requestID, capability: timed.capability, decision: .timedAllow(duration: 120))
        let lease = try XCTUnwrap(approvals.consumeForRuntime([
            .init(requestID: timed.requestID, capability: timed.capability, operationRequest: operation)
        ]))
        defer { lease.finish() }
        let cleanup = expectation(description: "pending event cleans prepared timed runtime authority")
        try lease.registerCleanup { cleanup.fulfill() }
        let onceRequest = request("once")
        let once = try approvals.submit(onceRequest, trustedCredentialDeadline: .none)
        _ = try approvals.decide(requestID: once.requestID, capability: once.capability, decision: .once)
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
        let queue = DispatchQueue(label: "askkey.tests.blocked-session-vault")
        let trace = SessionTrace()
        let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { .unlocked }, queue: queue,
            beginEndingEvent: { approvals.beginTimedAllowanceSessionEvent(sleeping: $0) },
            updateSession: { active, ending, suspended, sleeping, bound in
                XCTAssertFalse(Thread.isMainThread)
                trace.waitIfArmed(ending: ending)
                vault.updateTimedAllowanceSession(active: active, ending: ending, suspended: suspended,
                    sleeping: sleeping, sleepOffsetUpperBound: bound)
                trace.record(active: active, ending: ending, suspended: suspended, sleeping: sleeping)
            })
        defer { trace.release.signal(); queue.sync {}; withExtendedLifetime(observer) {} }
        queue.sync {}
        trace.arm()
        screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        XCTAssertEqual(trace.entered.wait(timeout: .now() + 2), .success)
        // The first Vault callback is still held open while all later posts return.
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(trace.values.count, 1, "Only the initial active update has completed")
        XCTAssertTrue(approvals.activeTimedAllowances().isEmpty)
        XCTAssertThrowsError(try lease.performAuthorizedSpawn { XCTFail("Pending ending events must refuse timed spawn") })
        wait(for: [cleanup], timeout: 2)
        let pending = try approvals.submit(request("pending"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        XCTAssertEqual(try approvals.consume(requestID: once.requestID, capability: once.capability,
            operationRequest: onceRequest), .consumed)
        trace.release.signal()
        queue.sync {}
        XCTAssertEqual(trace.values, [
            "true,false,false,nil", "false,true,false,nil", "true,false,false,nil",
            "true,true,false,true", "true,false,false,false", "false,true,true,nil", "true,false,false,nil"
        ])
        XCTAssertEqual(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
        XCTAssertThrowsError(try lease.validate(), "Resuming must never revive revoked authority")
    }

    func testDelayedWillSleepUsesReceiptBoundAndRequiresRealSleepOrDidWake() throws {
        for realSleep in [false, true] {
            let library = try AgentAccessPolicyTestLibrary()
            defer { try? library.close() }
            let vault = library.vault
            try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            let approvals = vault.approvalRequests
            approvals.configureAuthentication { _ in true }
            approvals.configureTimedAllowanceScreenState { true }
            let offset = SessionSleepOffset()
            approvals.configureTimedAllowanceSleepOffset { offset.current }
            let workspace = NotificationCenter()
            let queue = DispatchQueue(label: "askkey.tests.delayed-will-sleep")
            let trace = SessionTrace()
            let observer = TimedAllowanceSessionObserver(screenNotifications: .init(), workspaceNotifications: workspace,
                screenState: { .unlocked }, queue: queue,
                beginEndingEvent: { approvals.beginTimedAllowanceSessionEvent(sleeping: $0) },
                updateSession: { active, ending, suspended, sleeping, bound in
                    trace.waitIfArmed(ending: ending)
                    vault.updateTimedAllowanceSession(active: active, ending: ending, suspended: suspended,
                        sleeping: sleeping, sleepOffsetUpperBound: bound)
                })
            defer { trace.release.signal(); queue.sync {}; withExtendedLifetime(observer) {} }
            queue.sync {}
            trace.arm()
            workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
            XCTAssertEqual(trace.entered.wait(timeout: .now() + 2), .success)
            // Both iterations change the execution-time upper bound. Only the
            // real-sleep iteration separates the lower bound from receipt time.
            offset.advance(realSleep: realSleep)
            let pending = try approvals.submit(request("sleep-pending"), trustedCredentialDeadline: .none)
            XCTAssertThrowsError(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)), "Even clock proof must not bypass a queued ending event")
            trace.release.signal()
            queue.sync {}
            XCTAssertEqual(approvals.timedAllowanceSleepOffsetAtSleep, 100, "Use receipt time, not delayed callback time")
            if !realSleep {
                XCTAssertThrowsError(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                    decision: .timedAllow(duration: 120)))
                workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
                queue.sync {}
            }
            XCTAssertEqual(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
                decision: .timedAllow(duration: 120)).state, .approved)
        }
    }

    func testOffPolicyReadFailureFinishesFenceAndDoesNotStopLaterEventsOrReadScreenProvider() throws {
        let library = try AgentAccessPolicyTestLibrary()
        defer { try? library.close() }
        let vault = library.vault
        let approvals = vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        approvals.configureTimedAllowanceScreenState { XCTFail("Default-off events must not call the Broker provider"); return false }
        let screen = NotificationCenter()
        let workspace = NotificationCenter()
        let queue = DispatchQueue(label: "askkey.tests.session-policy-read-error")
        let trace = SessionTrace()
        let observer = TimedAllowanceSessionObserver(screenNotifications: screen, workspaceNotifications: workspace,
            screenState: { .unlocked }, queue: queue,
            beginEndingEvent: { approvals.beginTimedAllowanceSessionEvent(sleeping: $0) },
            updateSession: { active, ending, suspended, sleeping, bound in
                vault.updateTimedAllowanceSession(active: active, ending: ending, suspended: suspended,
                    sleeping: sleeping, sleepOffsetUpperBound: bound)
                trace.record(active: active, ending: ending, suspended: suspended, sleeping: sleeping)
            })
        defer { queue.sync {}; withExtendedLifetime(observer) {} }
        queue.sync {}
        let reads = library.keys.policyReads
        library.keys.loadFailure = VaultError.managementAuthenticationRequired
        screen.post(name: .init("com.apple.screenIsLocked"), object: nil)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        screen.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        queue.sync {}
        XCTAssertEqual(library.keys.policyReads, reads + 2, "Both off ending events still check for remote opt-in")
        XCTAssertEqual(trace.values.count, 5, "A failed policy read must not stop resume events")
        library.keys.loadFailure = nil
        approvals.configureTimedAllowanceScreenState { true }
        try vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        let pending = try approvals.submit(request("after-error"), trustedCredentialDeadline: .none)
        XCTAssertEqual(try approvals.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved, "Completed error paths must not leak a fence")
    }

    private func request(_ credential: String) -> BrokerApprovalOperationRequest {
        .init(operationID: UUID().uuidString, credentialID: credential, targetID: credential, operation: .read,
            payloadDigest: String(repeating: "a", count: 64))
    }
}

private final class SessionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var block = false
    private var recorded: [String] = []
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var values: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func arm() { lock.lock(); block = true; lock.unlock() }
    func waitIfArmed(ending: Bool) {
        lock.lock()
        let shouldWait = ending && block
        if shouldWait { block = false }
        lock.unlock()
        if shouldWait {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        }
    }
    func record(active: Bool, ending: Bool, suspended: Bool, sleeping: Bool?) {
        lock.lock()
        recorded.append("\(active),\(ending),\(suspended),\(sleeping.map(String.init) ?? "nil")")
        lock.unlock()
    }
}

private final class SessionSleepOffset: @unchecked Sendable {
    private let lock = NSLock()
    private var lower: UInt64 = 100
    private var upper: UInt64 = 100
    var current: (UInt64, UInt64) { lock.lock(); defer { lock.unlock() }; return (lower, upper) }
    func advance(realSleep: Bool) { lock.lock(); upper += 1; if realSleep { lower += 1 }; lock.unlock() }
}
