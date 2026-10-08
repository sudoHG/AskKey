import XCTest
@testable import AskKeyBroker

final class OrganizationApprovalTests: XCTestCase {
    private func request(ids: [String]? = ["a", "b"], credentialID: String = "", targetID: String = "credential-library",
                         operation: BrokerApprovalOperation = .organize) -> BrokerApprovalOperationRequest {
        .init(operationID: "batch", credentialID: credentialID, targetID: targetID, operation: operation,
            payloadDigest: String(repeating: "a", count: 64), organizationCredentialIDs: ids)
    }

    func testOrganizationSubjectRequiresSortedUniqueBindingAndCannotMasqueradeAsSingleCredential() throws {
        for invalid in [request(ids: nil), request(ids: ["b", "a"]), request(ids: ["a", "a"]), request(ids: [""]),
                        request(credentialID: "a"), request(targetID: "a"),
                        request(credentialID: "a", targetID: "a", operation: .modify)] {
            XCTAssertThrowsError(try BrokerApprovalStateMachine().submit(invalid)) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidRequest) }
        }
        XCTAssertEqual(try BrokerApprovalStateMachine().submit(request()).state, .pending)
        XCTAssertEqual(try BrokerApprovalStateMachine().submit(request(ids: [])).state, .pending)
    }

    func testConsumptionAndEqualityBindAllMembersAndOneTicket() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let original = request()
        let ticket = try machine.submit(original)
        XCTAssertEqual(machine.pendingRequests().count, 1)
        XCTAssertNotEqual(original, request(ids: ["a"]))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        XCTAssertThrowsError(try machine.consume(requestID: ticket.requestID, capability: ticket.capability, operationRequest: request(ids: ["a"]))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertEqual(try machine.consume(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original), .consumed)
        XCTAssertThrowsError(try machine.consume(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .alreadyConsumed)
        }
    }

    func testOrganizationWireResponsesContainNoAffectedIdentitiesOrCounts() throws {
        let write = AgentTextWriteRequest(operationID: "batch", action: .organize([.deleteGroup("Agent-known group")]))
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in .consumed },
            submitTextWrite: { request, _ in .completed(.init(operationID: request.operationID, credentialID: "hidden-identity")) },
            commitTextWrite: { request, _, _ in .init(operationID: request.operationID, credentialID: "hidden-identity") })
        for method in ["credential.write.request", "credential.write.commit"] {
            let result = handler.handle(.init(version: BrokerProtocolVersion.current, method: method,
                requestID: "request", capability: "capability", textWrite: write))
            XCTAssertEqual(result, .success(.organizationWriteResult(operationID: "batch")))
            let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
            for forbidden in ["hidden-identity", "organizationCredentialIDs", "Agent-known group", "members", "nonvisible"] {
                XCTAssertFalse(encoded.contains(forbidden))
            }
        }
    }

    func testCatalogGroupsAreAdditiveOnTheVersionOneBrokerPayload() throws {
        let legacy = Data(#"{"success":{"_0":{"catalog":{"_0":[]}}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BrokerResponse.self, from: legacy), .success(.catalog([], groups: nil)))
        let current = BrokerResponse.success(.catalog([], groups: ["Empty"]))
        XCTAssertEqual(try JSONDecoder().decode(BrokerResponse.self, from: JSONEncoder().encode(current)), current)
        XCTAssertEqual(BrokerProtocolVersion.current, 1)
    }
}
