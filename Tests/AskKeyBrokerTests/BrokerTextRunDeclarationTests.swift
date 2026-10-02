import XCTest
@testable import AskKeyBroker

final class BrokerTextRunDeclarationTests: XCTestCase {
    func testLegacyEncodedRequestDecodesWithoutCallerFields() throws {
        let json = """
        {"command":["/usr/bin/true"],"credentialNames":["TOKEN"],"inheritedEnvironment":{},"operationID":"legacy-op"}
        """
        let request = try JSONDecoder().decode(BrokerTextRunRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.operationID, "legacy-op")
        XCTAssertNil(request.callerName)
        XCTAssertNil(request.callerPurpose)
        XCTAssertTrue(request.declarationsAreValid)
        XCTAssertNil(request.sanitizedCallerName)
        XCTAssertNil(request.sanitizedCallerPurpose)
    }

    func testExplicitDeclarationsRoundTripAndStayOutOfInheritedEnvironment() throws {
        let request = BrokerTextRunRequest(
            operationID: "declared-op",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"],
            inheritedEnvironment: ["PATH": "/usr/bin", "SECRET": "must-not-travel"],
            callerName: "  Codex  ",
            callerPurpose: "deploy the nightly"
        )
        XCTAssertEqual(request.sanitizedCallerName, "Codex")
        XCTAssertEqual(request.sanitizedCallerPurpose, "deploy the nightly")
        let inherited = BrokerTextRunRequest.filteredInheritedEnvironment(request.inheritedEnvironment)
        XCTAssertEqual(inherited["PATH"], "/usr/bin")
        XCTAssertNil(inherited["SECRET"])

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BrokerTextRunRequest.self, from: encoded)
        XCTAssertEqual(decoded.callerName, "Codex")
        XCTAssertEqual(decoded.callerPurpose, "deploy the nightly")
        XCTAssertEqual(
            request,
            BrokerTextRunRequest(
                operationID: "declared-op",
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                inheritedEnvironment: ["PATH": "/usr/bin", "SECRET": "must-not-travel"],
                callerName: "Codex",
                callerPurpose: "deploy the nightly"
            )
        )
    }

    func testWhitespaceOnlyDeclarationChangesShareTheNormalizedDigest() throws {
        let ledger = BrokerRuntimeOperations()
        let first = BrokerTextRunRequest(
            operationID: "normalized-op",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"],
            callerName: "  Codex  ",
            callerPurpose: " deploy "
        )
        XCTAssertEqual(try ledger.perform(first, cancellation: .init()) { .exited(0) }, .exited(0))
        XCTAssertEqual(
            try ledger.perform(
                BrokerTextRunRequest(
                    operationID: "normalized-op",
                    command: ["/usr/bin/true"],
                    credentialNames: ["TOKEN"],
                    callerName: "Codex",
                    callerPurpose: "deploy"
                ),
                cancellation: .init()
            ) { XCTFail("normalized retransmission must reuse the receipt"); return .exited(1) },
            .exited(0)
        )
    }

    func testOverlongAndControlDeclarationsAreRejected() {
        let overlong = String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
        XCTAssertFalse(
            BrokerTextRunRequest(
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                callerName: overlong
            ).declarationsAreValid
        )
        XCTAssertFalse(
            BrokerTextRunRequest(
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                callerPurpose: "line\u{0007}bell"
            ).declarationsAreValid
        )
        XCTAssertTrue(
            BrokerTextRunRequest(
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                callerName: "   ",
                callerPurpose: nil
            ).declarationsAreValid
        )
    }

    func testChangingDeclarationOnTheSameOperationIsAPayloadMismatch() throws {
        let ledger = BrokerRuntimeOperations()
        let first = BrokerTextRunRequest(
            operationID: "same-op",
            command: ["/usr/bin/true"],
            credentialNames: ["TOKEN"],
            callerName: "Codex",
            callerPurpose: "first purpose"
        )
        XCTAssertEqual(try ledger.perform(first, cancellation: .init()) { .exited(0) }, .exited(0))
        XCTAssertThrowsError(try ledger.perform(
            BrokerTextRunRequest(
                operationID: "same-op",
                command: ["/usr/bin/true"],
                credentialNames: ["TOKEN"],
                callerName: "Codex",
                callerPurpose: "replaced after freeze"
            ),
            cancellation: .init()
        ) { .exited(0) }) {
            XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch)
        }
    }
}
