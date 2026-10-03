import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentTextWriteConcurrencyTests: AgentTextWriteTestSupport {
    func testConcurrentRetransmissionsShareRequestAndCommittedResult() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let request = AgentTextWriteRequest(
            operationID: "concurrent-create",
            action: .create(name: "Concurrent Create", value: "one-value")
        )
        let submissions = ConcurrentResults<AgentTextWriteSubmission>()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            submissions.append(Result {
                try submitted(harness.vault.requestAgentTextWrite(request))
            })
        }
        let tickets = try submissions.values.map { try $0.get() }
        XCTAssertEqual(Set(tickets.map(\.requestID)).count, 1)
        XCTAssertEqual(Set(tickets.map(\.capability)).count, 1)
        let ticket = try XCTUnwrap(tickets.first)
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )

        let commits = ConcurrentResults<AgentTextWriteResult>()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            commits.append(Result {
                try harness.vault.commitAgentTextWrite(
                    request,
                    requestID: ticket.requestID,
                    capability: ticket.capability
                )
            })
        }
        let results = try commits.values.map { try $0.get() }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first, results.last)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [result.credentialID])
    }
}
