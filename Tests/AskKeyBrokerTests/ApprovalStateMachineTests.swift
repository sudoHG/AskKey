import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineTests: XCTestCase {
    func testVaultLockRevokesEveryTimedAllowance() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let first = try machine.submit(request(operationID: "first"))
        _ = try machine.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .timedAllow(duration: 1_800)
        )

        machine.revokeAllTimedAllowances()

        XCTAssertEqual(try machine.submit(request(operationID: "after-lock")).state, .pending)
    }

    func testPendingRequestsExposeConfirmationContextWithoutCredentialValues() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let machine = BrokerApprovalStateMachine(clock: { now })
        let request = BrokerApprovalOperationRequest(
            operationID: String(repeating: "a", count: 64),
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .read,
            payloadDigest: String(repeating: "b", count: 64),
            callerName: "Codex",
            callerPurpose: "Deploy the release"
        )
        let ticket = try machine.submit(request, trustedCredentialDeadline: .none)

        XCTAssertEqual(
            machine.pendingRequests(),
            [BrokerPendingApproval(
                requestID: ticket.requestID,
                capability: ticket.capability,
                request: request,
                expiresAt: now.addingTimeInterval(5 * 60)
            )]
        )
    }

    func testAppCanConfigureApprovalAuthenticationBeforeDecision() throws {
        let machine = BrokerApprovalStateMachine()
        let purposes = AuthenticationRecorder()
        machine.configureAuthentication { purpose in
            purposes.record(purpose)
            return true
        }
        let request = BrokerApprovalOperationRequest(
            operationID: String(repeating: "c", count: 64),
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .read,
            payloadDigest: String(repeating: "d", count: 64)
        )
        let ticket = try machine.submit(request, trustedCredentialDeadline: .none)

        XCTAssertEqual(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertEqual(purposes.values, [.readApproval])
    }
    func testRetransmissionReturnsTheExistingCapabilityAndRejectsPayloadSwap() throws {
        let machine = BrokerApprovalStateMachine()
        let request = BrokerApprovalOperationRequest(
            operationID: "operation-1",
            credentialID: "credential-1",
            targetID: "credential-1",
            operation: .read,
            payloadDigest: String(repeating: "a", count: 64)
        )

        let first = try machine.submit(request)
        let retry = try machine.submit(request)

        XCTAssertEqual(first.requestID, retry.requestID)
        XCTAssertEqual(first.capability, retry.capability)
        XCTAssertEqual(first.retryCount, 0)
        XCTAssertEqual(retry.retryCount, 1)
        XCTAssertEqual(retry.state, .pending)
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "operation-1",
                    credentialID: "credential-1",
                    targetID: "credential-1",
                    operation: .read,
                    payloadDigest: String(repeating: "b", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
    }

    func testDenialHasNoCooldownAndOnceApprovalCanOnlyBeConsumedOnce() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let denied = try machine.submit(request(operationID: "operation-denied"))
        XCTAssertEqual(
            try machine.decide(
                requestID: denied.requestID,
                capability: denied.capability,
                decision: .deny
            ).state,
            .denied
        )

        let next = try machine.submit(request(operationID: "operation-next"))
        XCTAssertNotEqual(next.requestID, denied.requestID)
        XCTAssertEqual(next.state, .pending)
        XCTAssertEqual(
            try machine.decide(
                requestID: next.requestID,
                capability: next.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(
                    operationID: "operation-next",
                    digest: String(repeating: "b", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertEqual(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(operationID: "operation-next")
            ),
            .consumed
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(operationID: "operation-next")
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .alreadyConsumed)
        }
    }

    func testPendingRequestExpiresAfterFiveMinutesAndCancellationCannotBeReused() throws {
        let authentications = AuthenticationRecorder()
        let created = Date(timeIntervalSince1970: 1_000)
        let machine = BrokerApprovalStateMachine(clock: { created }, authenticate: {
            authentications.record($0)
            return true
        })
        let expiring = try machine.submit(request(operationID: "expiring"), now: created)

        XCTAssertEqual(
            try machine.status(
                requestID: expiring.requestID,
                capability: expiring.capability,
                now: created.addingTimeInterval(299)
            ),
            .pending
        )
        XCTAssertThrowsError(
            try machine.status(
                requestID: expiring.requestID,
                capability: "wrong-capability",
                now: created
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertEqual(
            try machine.status(
                requestID: expiring.requestID,
                capability: expiring.capability,
                now: created.addingTimeInterval(300)
            ),
            .expired
        )
        XCTAssertThrowsError(
            try machine.decide(
                requestID: expiring.requestID,
                capability: expiring.capability,
                decision: .once,
                now: created.addingTimeInterval(300)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertTrue(authentications.values.isEmpty)

        let cancelled = try machine.submit(request(operationID: "cancelled"), now: created)
        XCTAssertEqual(
            try machine.cancel(
                requestID: cancelled.requestID,
                capability: cancelled.capability,
                now: created
            ),
            .cancelled
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: cancelled.requestID,
                capability: cancelled.capability,
                operationRequest: request(operationID: "cancelled")
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }

    func testTimedAllowanceIsGlobalForOneCredentialReadAndNeverCoversWrites() throws {
        let authentications = AuthenticationRecorder()
        let start = Date(timeIntervalSince1970: 10_000)
        let machine = BrokerApprovalStateMachine(clock: { start }, authenticate: {
            authentications.record($0)
            return true
        })
        let first = try machine.submit(request(operationID: "first"), now: start)
        XCTAssertEqual(
            try machine.decide(
                requestID: first.requestID,
                capability: first.capability,
                decision: .timedAllow(duration: nil),
                now: start
            ).state,
            .approved
        )

        let sameCredential = try machine.submit(
                request(operationID: "same-credential"),
                now: start.addingTimeInterval(1_799)
            )
        XCTAssertEqual(sameCredential.state, .approved)
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "other-credential", credentialID: "credential-2"),
                now: start.addingTimeInterval(1)
            ).state,
            .pending
        )
        let write = try machine.submit(
            request(operationID: "write", operation: .modify),
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(write.state, .pending)
        XCTAssertThrowsError(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .timedAllow(duration: nil),
                now: start.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .once,
                now: start.addingTimeInterval(1)
            ).state,
            .approved
        )
        XCTAssertEqual(authentications.values, [.readApproval, .writeApproval])

        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "credential-1"))
        XCTAssertEqual(
            try machine.status(
                requestID: sameCredential.requestID,
                capability: sameCredential.capability,
                now: start.addingTimeInterval(1_799)
            ),
            .cancelled
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: sameCredential.requestID,
                capability: sameCredential.capability,
                operationRequest: request(operationID: "same-credential"),
                now: start.addingTimeInterval(1_799)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "after-revoke"),
                now: start.addingTimeInterval(2)
            ).state,
            .pending
        )
        let expiryMachine = BrokerApprovalStateMachine(clock: { start }, authenticate: { _ in true })
        let expiryFirst = try expiryMachine.submit(request(operationID: "expiry-first"), now: start)
        _ = try expiryMachine.decide(
            requestID: expiryFirst.requestID,
            capability: expiryFirst.capability,
            decision: .timedAllow(duration: nil),
            now: start
        )
        XCTAssertEqual(
            try expiryMachine.submit(
                request(operationID: "after-expiry"),
                now: start.addingTimeInterval(1_800)
            ).state,
            .pending
        )

        let allowanceClock = TestClock(start)
        let allowanceMachine = BrokerApprovalStateMachine(
            clock: { allowanceClock.now },
            authenticate: { _ in true }
        )
        let allowanceFirst = try allowanceMachine.submit(request(operationID: "short-window"))
        _ = try allowanceMachine.decide(
            requestID: allowanceFirst.requestID,
            capability: allowanceFirst.capability,
            decision: .timedAllow(duration: 60)
        )
        allowanceClock.advance(by: 59)
        let preapproved = try allowanceMachine.submit(request(operationID: "preapproved"))
        XCTAssertEqual(preapproved.state, .approved)
        allowanceClock.advance(by: 1)
        XCTAssertEqual(
            try allowanceMachine.status(
                requestID: preapproved.requestID,
                capability: preapproved.capability
            ),
            .expired
        )
    }

    func testExplicitTimedAllowanceShortensTheCurrentRequestDeadline() throws {
        let start = Date(timeIntervalSince1970: 50_000)
        let clock = TestClock(start)
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let operation = request(operationID: "explicit-short-window")
        let ticket = try machine.submit(operation)
        XCTAssertEqual(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .timedAllow(duration: 60)
            ).state,
            .approved
        )

        clock.advance(by: 60)
        XCTAssertEqual(
            try machine.status(requestID: ticket.requestID, capability: ticket.capability),
            .expired
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: ticket.requestID,
                capability: ticket.capability,
                operationRequest: operation
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }

    func testReadAuthenticationCanBeDisabledButWriteAuthenticationFailsClosed() throws {
        let authentications = AuthenticationRecorder()
        let machine = BrokerApprovalStateMachine(
            readAuthenticationEnabled: false,
            authenticate: {
                authentications.record($0)
                return false
            }
        )
        let read = try machine.submit(request(operationID: "read"))
        XCTAssertEqual(
            try machine.decide(
                requestID: read.requestID,
                capability: read.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertTrue(authentications.values.isEmpty)

        let write = try machine.submit(request(operationID: "write", operation: .delete))
        XCTAssertThrowsError(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .once
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(authentications.values, [.writeApproval])
        XCTAssertEqual(
            try machine.status(requestID: write.requestID, capability: write.capability),
            .pending
        )
    }


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

    func testExternalFieldsAndPendingQueueAreBounded() throws {
        let machine = BrokerApprovalStateMachine()
        XCTAssertThrowsError(
            try machine.submit(request(operationID: ""))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "wrong-modify-target",
                    credentialID: "credential-1",
                    targetID: "credential-2",
                    operation: .modify,
                    payloadDigest: String(repeating: "a", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "wrong-read-target",
                    credentialID: "credential-1",
                    targetID: "credential-2",
                    operation: .read,
                    payloadDigest: String(repeating: "a", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                request(
                    operationID: "oversized",
                    digest: String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }

        var first: BrokerApprovalTicket?
        for index in 0..<BrokerLimits.maximumPendingApprovalRequests {
            let ticket = try machine.submit(request(operationID: "operation-\(index)"))
            if first == nil { first = ticket }
        }
        XCTAssertThrowsError(
            try machine.submit(request(operationID: "overflow"))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .capacityReached)
        }
        guard let first else { return XCTFail("expected the first pending request") }
        _ = try machine.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .deny
        )
        XCTAssertNoThrow(try machine.submit(request(operationID: "replacement")))

        let allowedMachine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let allowance = try allowedMachine.submit(request(operationID: "allowance"))
        _ = try allowedMachine.decide(
            requestID: allowance.requestID,
            capability: allowance.capability,
            decision: .timedAllow(duration: nil)
        )
        for index in 0..<(BrokerLimits.maximumPendingApprovalRequests - 1) {
            _ = try allowedMachine.submit(
                request(operationID: "other-\(index)", credentialID: "other-\(index)")
            )
        }
        XCTAssertThrowsError(
            try allowedMachine.submit(request(operationID: "allowed-despite-full-queue"))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .capacityReached)
        }
    }

    func testApprovedRequestExpiresAndAuthenticationCannotCrossTheDeadline() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 30_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in
                clock.advance(by: 300)
                return true
            }
        )
        let slowRequest = request(operationID: "slow-auth")
        let ticket = try machine.submit(slowRequest, now: clock.now)

        XCTAssertThrowsError(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .once,
                now: Date(timeIntervalSince1970: 30_000)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.status(requestID: ticket.requestID, capability: ticket.capability, now: clock.now),
            .expired
        )

        let approvedMachine = BrokerApprovalStateMachine(clock: { clock.now }, authenticate: { _ in true })
        let approvedRequest = request(operationID: "approved-expiry")
        let approved = try approvedMachine.submit(approvedRequest, now: clock.now)
        _ = try approvedMachine.decide(
            requestID: approved.requestID,
            capability: approved.capability,
            decision: .once,
            now: clock.now
        )
        clock.advance(by: 300)
        XCTAssertEqual(
            try approvedMachine.status(
                requestID: approved.requestID,
                capability: approved.capability,
                now: clock.now
            ),
            .expired
        )
        XCTAssertThrowsError(
            try approvedMachine.consume(
                requestID: approved.requestID,
                capability: approved.capability,
                operationRequest: approvedRequest,
                now: clock.now
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }

        let rollbackClock = TestClock(Date(timeIntervalSince1970: 40_000))
        let rollbackMachine = BrokerApprovalStateMachine(
            clock: { rollbackClock.now },
            authenticate: { _ in true }
        )
        let rollbackRequest = request(operationID: "rollback")
        let rollback = try rollbackMachine.submit(rollbackRequest, now: rollbackClock.now)
        _ = try rollbackMachine.decide(
            requestID: rollback.requestID,
            capability: rollback.capability,
            decision: .once,
            now: rollbackClock.now
        )
        rollbackClock.advance(by: 300)
        XCTAssertThrowsError(
            try rollbackMachine.consume(
                requestID: rollback.requestID,
                capability: rollback.capability,
                operationRequest: rollbackRequest
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }

    func testConcurrentCountCallbacksCannotPublishAnOlderCountLast() throws {
        let recorder = OrderedCountRecorder()
        let machine = BrokerApprovalStateMachine(
            pendingCountChanged: { recorder.record($0) }
        )
        let firstRequest = request(operationID: "first-callback")
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(firstRequest)
            firstFinished.signal()
        }
        XCTAssertEqual(recorder.firstEntered.wait(timeout: .now() + 2), .success)

        let secondRequest = request(operationID: "second-callback")
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(secondRequest)
            secondFinished.signal()
        }
        _ = recorder.secondEntered.wait(timeout: .now() + 0.2)
        recorder.releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        machine.flushObservers()

        XCTAssertEqual(recorder.values, [1, 2])
    }

    func testRuntimeAuthorizationSurvivesTicketEvictionButNeverRevocationOrRenewal() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let machine = BrokerApprovalStateMachine(clock: { clock.now }, authenticate: { _ in true })
        let original = request(operationID: "runtime-original")
        let ticket = try machine.submit(original)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                               decision: .timedAllow(duration: 30))
        let lease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
        ]))
        defer { lease.finish() }
        for index in 0..<BrokerLimits.maximumRetainedRequestStates {
            let other = try machine.submit(request(operationID: "evict-\(index)", credentialID: "other"))
            _ = try machine.decide(requestID: other.requestID, capability: other.capability, decision: .deny)
        }
        XCTAssertThrowsError(try machine.status(requestID: ticket.requestID, capability: ticket.capability)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertNoThrow(try lease.validate(), "ticket retention does not shorten a live authorization")
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "credential-1"))
        XCTAssertThrowsError(try lease.validate())
        let renewed = request(operationID: "runtime-renewed")
        let renewedTicket = try machine.submit(renewed)
        _ = try machine.decide(requestID: renewedTicket.requestID, capability: renewedTicket.capability,
                               decision: .timedAllow(duration: 30))
        let freshLease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: renewedTicket.requestID, capability: renewedTicket.capability, operationRequest: renewed),
        ]))
        defer { freshLease.finish() }
        XCTAssertNoThrow(try freshLease.validate())
        XCTAssertThrowsError(try lease.validate(), "a new allowance cannot resurrect the evicted old consumption")
    }

    func testRuntimeAuthorizationKeepsItsOriginalDeadlineAndCleanupCanReenterStateMachine() throws {
        for decision in [BrokerApprovalDecision.once, .timedAllow(duration: 30)] {
            let start = Date(timeIntervalSince1970: 10_000)
            let clock = TestClock(start)
            let machine = BrokerApprovalStateMachine(requestTTL: 120, clock: { clock.now }, authenticate: { _ in true })
            let original = request(operationID: "original-deadline")
            let ticket = try machine.submit(original)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            let lease = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
            ]))
            defer { lease.finish() }
            let expectedDuration: TimeInterval = decision == .once ? 120 : 30
            XCTAssertEqual(lease.expiresAt, start.addingTimeInterval(expectedDuration))
            let cleaned = expectation(description: "exact authorization deadline cleanup")
            try lease.registerCleanup {
                _ = machine.pendingRequests()
                cleaned.fulfill()
            }
            clock.advance(by: expectedDuration)
            let sweepFinished = expectation(description: "expiry sweep returns after reentrant cleanup")
            DispatchQueue.global().async {
                _ = machine.timedAllowanceDeadline(credentialID: "credential-1")
                sweepFinished.fulfill()
            }
            wait(for: [cleaned, sweepFinished], timeout: 2)
            XCTAssertThrowsError(try lease.validate())
        }
    }

    private func request(
        operationID: String,
        credentialID: String = "credential-1",
        operation: BrokerApprovalOperation = .read,
        digest: String = String(repeating: "a", count: 64)
    ) -> BrokerApprovalOperationRequest {
        .init(
            operationID: operationID,
            credentialID: credentialID,
            targetID: credentialID,
            operation: operation,
            payloadDigest: digest
        )
    }
}

private final class AuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BrokerAuthenticationPurpose] = []

    var values: [BrokerAuthenticationPurpose] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ purpose: BrokerAuthenticationPurpose) {
        lock.lock(); defer { lock.unlock() }
        storage.append(purpose)
    }
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationStorage: [BrokerPrivacyNotification] = []
    private var countStorage: [Int] = []

    var notifications: [BrokerPrivacyNotification] {
        lock.lock(); defer { lock.unlock() }
        return notificationStorage
    }

    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }

    func record(notification: BrokerPrivacyNotification) {
        lock.lock(); defer { lock.unlock() }
        notificationStorage.append(notification)
    }

    func record(count: Int) {
        lock.lock(); defer { lock.unlock() }
        countStorage.append(count)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(interval)
    }
}

private final class OrderedCountRecorder: @unchecked Sendable {
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ count: Int) {
        if count == 1 {
            firstEntered.signal()
            releaseFirst.wait()
        }
        if count == 2 { secondEntered.signal() }
        lock.lock(); defer { lock.unlock() }
        storage.append(count)
    }
}

private final class ExpirationObserverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let expired: XCTestExpectation
    private var countStorage: [Int] = []
    private var notificationStorage: [BrokerPrivacyNotification] = []
    private var didFulfillExpiry = false

    init(expired: XCTestExpectation) {
        self.expired = expired
    }

    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }

    var notifications: [BrokerPrivacyNotification] {
        lock.lock(); defer { lock.unlock() }
        return notificationStorage
    }

    func record(count: Int) {
        lock.lock()
        countStorage.append(count)
        let shouldFulfill = count == 0 && !didFulfillExpiry
        if shouldFulfill { didFulfillExpiry = true }
        lock.unlock()
        if shouldFulfill { expired.fulfill() }
    }

    func record(notification: BrokerPrivacyNotification) {
        lock.lock(); defer { lock.unlock() }
        notificationStorage.append(notification)
    }
}
