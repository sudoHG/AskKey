import XCTest
@testable import AskKeyBroker

final class ReadProjectionAllowanceTests: ApprovalStateMachineTestCase {
    func testTimedAllowanceMatchesProjectionAndBindingIsClearedByEveryRevocationPath() throws {
        for action in ["revoke", "all", "credential", "pause", "expire"] {
            let start = Date(timeIntervalSince1970: 1_000)
            let machine = configuredMachine(clock: { start }, authenticate: { _ in true })
            let first = projectionRequest("first", digest: "a")
            let ticket = try machine.submit(first, now: start)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                decision: .timedAllow(duration: 60), now: start)
            XCTAssertEqual(try machine.submit(projectionRequest("same", digest: "a"), now: start).state, .approved)
            XCTAssertEqual(try machine.submit(projectionRequest("different", digest: "b"), now: start).state, .pending)
            XCTAssertEqual(try machine.submit(request(operationID: "unbound"), now: start).state, .pending)
            switch action {
            case "revoke": _ = machine.revokeTimedAllowance(credentialID: first.credentialID)
            case "all": machine.revokeAllTimedAllowances()
            case "credential": _ = machine.cancelPending(credentialID: first.credentialID)
            case "pause": machine.pauseAndCancelAll()
            default: machine.mutate { machine.expireTimedAllowancesLocked(now: start.addingTimeInterval(61)) }
            }
            XCTAssertTrue(machine.timedAllowanceProjectionDigests.isEmpty, action)
        }
    }

    func testProjectionBindingParticipatesInEqualityAndConsumption() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let first = projectionRequest("first", digest: "a")
        let changed = projectionRequest("first", digest: "b")
        XCTAssertNotEqual(first, changed)
        let ticket = try machine.submit(first)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        XCTAssertThrowsError(try machine.consume(requestID: ticket.requestID, capability: ticket.capability, operationRequest: changed)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
    }

    private func projectionRequest(_ operationID: String, digest: String) -> BrokerApprovalOperationRequest {
        .init(operationID: operationID, credentialID: "credential-1", targetID: "credential-1", operation: .read,
            payloadDigest: String(repeating: "f", count: 64), readProjectionDigest: String(repeating: digest, count: 64))
    }
}
