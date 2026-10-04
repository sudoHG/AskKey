import XCTest
@testable import AskKeyBroker

final class ApprovalDisplayTests: XCTestCase {
    func testDisplayChangesPreserveEqualityAndConsumptionBinding() {
        let original = request(display: display("original"))
        for replacement in [nil, display("replacement")] {
            let changed = request(display: replacement)
            XCTAssertEqual(original, changed)
            XCTAssertTrue(original.matchesForConsumption(changed))
        }
        let changedBindings = [
            request(operationID: "other"), request(credentialID: "other"),
            request(targetID: "other"), request(operation: .modify),
            request(digest: String(repeating: "b", count: 64)),
            request(retransmissionDigest: String(repeating: "c", count: 64)),
            request(credentialName: "other"), request(callerName: "other"),
            request(callerPurpose: "other"),
        ]
        for changed in changedBindings {
            XCTAssertNotEqual(original, changed)
            XCTAssertFalse(original.matchesForConsumption(changed))
        }
    }

    func testDisplayReplacementReusesTicketAndConsumesOriginalApproval() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let original = request(display: display("original"))
        let changed = request(display: display("replacement"))
        let ticket = try machine.submit(original)
        let retransmitted = try machine.submit(changed)
        XCTAssertEqual(ticket.requestID, retransmitted.requestID)
        XCTAssertEqual(ticket.capability, retransmitted.capability)
        XCTAssertEqual(machine.pendingRequests().first?.request.display, original.display)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        let authorization = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: changed),
        ]))
        defer { authorization.finish() }
        XCTAssertNoThrow(try authorization.validate())
    }

    func testDisplayCannotOverridePayloadOrRetransmissionDigests() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let original = request(display: display("original"))
        let ticket = try machine.submit(original)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        let changedDigest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try machine.submit(request(digest: changedDigest, display: original.display))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertThrowsError(try machine.terminalRetransmission(operationID: original.operationID,
                                                              payloadDigest: changedDigest)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
    }

    func testCommandSummaryTruncatesInMiddleAndRetainsFullText() {
        for count in [0, 159, 160] {
            let command = String(repeating: "x", count: count)
            XCTAssertEqual(display(command).commandSummary, command)
        }
        let command = String(repeating: "🙂", count: 81) + "middle" + String(repeating: "z", count: 80)
        let value = display(command)
        XCTAssertEqual(value.commandLine, command)
        XCTAssertEqual(value.commandSummary.count, 160)
        XCTAssertEqual(value.commandSummary, String(command.prefix(80)) + "…" + String(command.suffix(79)))
    }

    func testDisplayContextDoesNotReachPrivacyNotification() throws {
        let recorder = NotificationRecorder()
        let machine = BrokerApprovalStateMachine(notify: { recorder.record(notification: $0) })
        _ = try machine.submit(request(display: display("synthetic-private-argument")))
        machine.flushObservers()
        XCTAssertEqual(recorder.notifications, [.approvalQueueBecameNonempty])
    }

    private func display(_ command: String) -> BrokerApprovalOperationRequest.Display {
        .init(commandLine: command, workingDirectory: "~/synthetic", executableBasename: "tool",
              environmentVariables: ["TOKEN"], temporaryFileVariables: ["KEY_FILE"])
    }

    private func request(
        operationID: String = "operation", credentialID: String = "credential", targetID: String = "credential",
        operation: BrokerApprovalOperation = .read, digest: String = String(repeating: "a", count: 64),
        retransmissionDigest: String? = nil, credentialName: String? = "Synthetic",
        callerName: String? = "caller", callerPurpose: String? = "purpose",
        display: BrokerApprovalOperationRequest.Display? = nil
    ) -> BrokerApprovalOperationRequest {
        .init(operationID: operationID, credentialID: credentialID, targetID: targetID, operation: operation,
              payloadDigest: digest, credentialName: credentialName, callerName: callerName,
              callerPurpose: callerPurpose, retransmissionDigest: retransmissionDigest, display: display)
    }
}
