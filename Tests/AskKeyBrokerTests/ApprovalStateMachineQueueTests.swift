import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineQueueTests: ApprovalStateMachineTestCase {
    func testQueueNotifiesOnlyOnEmptyTransitionAndNotificationIsPrivate() throws {
        let notifications = NotificationRecorder()
        let machine = BrokerApprovalStateMachine(
            notify: { notifications.record(notification: $0) },
            pendingCountChanged: { notifications.record(count: $0) }
        )
        let first = try machine.submit(
            .init(
                operationID: "operation-secret",
                credentialID: "credential-secret",
                targetID: "target-secret",
                operation: .create,
                payloadDigest: String(repeating: "d", count: 64),
                callerName: "caller-secret",
                callerPurpose: "purpose-secret"
            )
        )
        _ = try machine.submit(
            .init(
                operationID: "operation-secret",
                credentialID: "credential-secret",
                targetID: "target-secret",
                operation: .create,
                payloadDigest: String(repeating: "d", count: 64),
                callerName: "caller-secret",
                callerPurpose: "purpose-secret"
            )
        )
        let second = try machine.submit(request(operationID: "operation-2"))
        machine.flushObservers()

        XCTAssertEqual(notifications.counts, [1, 2])
        XCTAssertEqual(notifications.notifications, [.approvalQueueBecameNonempty])
        let encoded = try JSONEncoder().encode(notifications.notifications[0])
        let notificationText = String(decoding: encoded, as: UTF8.self)
        for privateValue in [
            "credential-secret", "target-secret", String(repeating: "d", count: 64),
            "caller-secret", "purpose-secret"
        ] {
            XCTAssertFalse(notificationText.contains(privateValue))
        }
        XCTAssertTrue(notifications.notifications[0].actions.isEmpty)

        _ = try machine.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .deny
        )
        _ = try machine.decide(
            requestID: second.requestID,
            capability: second.capability,
            decision: .deny
        )
        _ = try machine.submit(request(operationID: "operation-3"))
        machine.flushObservers()

        XCTAssertEqual(notifications.counts, [1, 2, 1, 0, 1])
        XCTAssertEqual(
            notifications.notifications,
            [.approvalQueueBecameNonempty, .approvalQueueBecameNonempty]
        )
    }
    func testDeadlineActivelyClearsCountAndRearmsNotificationWithoutAnotherCall() throws {
        let expired = expectation(description: "pending request expires")
        let recorder = ExpirationObserverRecorder(expired: expired)
        let machine = BrokerApprovalStateMachine(
            requestTTL: 0.05,
            notify: { recorder.record(notification: $0) },
            pendingCountChanged: { recorder.record(count: $0) }
        )

        _ = try machine.submit(request(operationID: "first-expiring"))
        machine.flushObservers()
        XCTAssertEqual(recorder.counts, [1])
        wait(for: [expired], timeout: 1)
        machine.flushObservers()
        XCTAssertEqual(recorder.counts, [1, 0])

        _ = try machine.submit(request(operationID: "second-expiring"))
        machine.flushObservers()
        XCTAssertEqual(recorder.counts, [1, 0, 1])
        XCTAssertEqual(
            recorder.notifications,
            [.approvalQueueBecameNonempty, .approvalQueueBecameNonempty]
        )
    }
    func testExpirationSchedulingStaysBoundedAcrossCancelAndRetentionEviction() throws {
        let machine = BrokerApprovalStateMachine()

        for index in 0..<300 {
            let ticket = try machine.submit(request(operationID: "timer-churn-\(index)"))
            XCTAssertEqual(machine.scheduledExpirationTaskCount, 1)
            XCTAssertEqual(
                try machine.cancel(requestID: ticket.requestID, capability: ticket.capability),
                .cancelled
            )
            XCTAssertEqual(machine.scheduledExpirationTaskCount, 0)
        }
    }
    func testPauseAndCredentialRevocationCancelRequestsAndTimedAllowances() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let machine = BrokerApprovalStateMachine(clock: { now }, authenticate: { _ in true })
        let allowed = try machine.submit(request(operationID: "allow"), now: now)
        _ = try machine.decide(
            requestID: allowed.requestID,
            capability: allowed.capability,
            decision: .timedAllow(duration: nil),
            now: now
        )
        let pending = try machine.submit(request(operationID: "pending"), now: now)

        XCTAssertEqual(machine.cancelPending(credentialID: "credential-1"), 2)
        XCTAssertEqual(
            try machine.status(requestID: allowed.requestID, capability: allowed.capability, now: now),
            .cancelled
        )
        XCTAssertEqual(
            try machine.status(requestID: pending.requestID, capability: pending.capability, now: now),
            .cancelled
        )
        XCTAssertEqual(
            try machine.submit(request(operationID: "after-change"), now: now).state,
            .pending
        )

        machine.pauseAndCancelAll()
        XCTAssertThrowsError(try machine.submit(request(operationID: "while-paused"), now: now)) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .agentAccessPaused)
        }
        machine.resume()
        XCTAssertEqual(
            try machine.submit(request(operationID: "after-resume"), now: now).state,
            .pending
        )
    }
}
