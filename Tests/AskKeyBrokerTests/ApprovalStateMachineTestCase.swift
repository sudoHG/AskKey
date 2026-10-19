import XCTest
@testable import AskKeyBroker

class ApprovalStateMachineTestCase: XCTestCase {
    func configuredMachine(
        requestTTL: TimeInterval = 5 * 60,
        defaultTimedAllowance: TimeInterval = 30 * 60,
        readAuthenticationEnabled: Bool = true,
        timedAllowanceEnabled: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() },
        authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool = { _ in false },
        timedAllowanceRevoked: @escaping @Sendable (String) -> Void = { _ in }
    ) -> BrokerApprovalStateMachine {
        let machine = BrokerApprovalStateMachine(
            requestTTL: requestTTL,
            readAuthenticationEnabled: readAuthenticationEnabled,
            clock: clock,
            authenticate: authenticate,
            timedAllowanceRevoked: timedAllowanceRevoked
        )
        machine.configureAgentAccessPolicy(
            readAuthenticationEnabled: readAuthenticationEnabled,
            timedAllowanceEnabled: timedAllowanceEnabled,
            timedAllowanceDuration: defaultTimedAllowance
        )
        return machine
    }

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
