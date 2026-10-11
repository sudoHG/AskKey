import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentApprovalExpiryRecordTests: AgentOrganizationTestSupport {
    func testExpiredCreateIsRecordedAsExpiredWithoutCreatingCredential() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 2_000_000_000))
        let machine = BrokerApprovalStateMachine(clock: { clock.now })
        let harness = try makeHarness(now: { clock.now }, approvalRequests: machine, authenticate: { _ in true })
        _ = try submitted(harness.vault.requestAgentTextWrite(.init(
            operationID: "away-create", action: .create(name: "Synthetic", value: "synthetic-value")
        )))
        clock.now.addTimeInterval(301)
        XCTAssertTrue(machine.pendingRequests().isEmpty)
        try harness.vault.beginManagementSession(using: .allow)
        let records = try harness.vault.listCredentialAccessRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.result, .expired)
        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
    }

    func testExpiryDenialAndCancellationKeepDistinctTerminalRecords() throws {
        for state in [BrokerRequestState.expired, .denied, .cancelled] {
            let clock = MutableClock(Date(timeIntervalSince1970: 2_000_000_000))
            let machine = BrokerApprovalStateMachine(clock: { clock.now })
            let harness = try makeHarness(now: { clock.now }, approvalRequests: machine, authenticate: { _ in true })
            let credential = try credential("Synthetic", group: "Original", harness: harness)
            let operation = request([.renameGroup(from: "Original", to: "Changed")], id: "away-organize")
            let ticket = try submitted(harness.vault.requestAgentTextWrite(operation))
            switch state {
            case .expired:
                clock.now.addTimeInterval(301)
                machine.refreshExpiration()
                try harness.vault.beginManagementSession(using: .allow)
            case .denied:
                _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny)
            case .cancelled:
                _ = try harness.vault.cancelAgentTextWrite(operationID: operation.operationID, requestID: ticket.requestID, capability: ticket.capability)
            default: XCTFail("Unexpected state")
            }
            let records = try harness.vault.listCredentialAccessRecords()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.result, state == .expired ? .expired : .denied)
            XCTAssertEqual(try group(credential.id, harness: harness), "Original")
            XCTAssertThrowsError(try commit(operation, harness: harness, ticket: ticket))
            machine.refreshExpiration()
            XCTAssertEqual(try harness.vault.listCredentialAccessRecords().count, 1)
        }
    }

    func testExpiredResultRoundTripsAndOldDeniedRecordsStillDecode() throws {
        for result in [CredentialAccessEvent.Result.denied, .expired] {
            let event = CredentialAccessEvent(timestamp: Date(), credentialID: "synthetic", operation: .create,
                result: result, callerHint: nil, declaredPurpose: nil)
            XCTAssertEqual(try JSONDecoder().decode(CredentialAccessEvent.self, from: JSONEncoder().encode(event)), event)
        }
    }
}
