import XCTest
@testable import AskKeyBroker

class ApprovalStateMachineTestCase: XCTestCase {
    func request(
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
