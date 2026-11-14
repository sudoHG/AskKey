import XCTest
@testable import AskKeyBroker

/// Helpers for the remote decision path (ADR 0014). Pairing IDs and device
/// names are synthetic.
class RemoteApprovalTestCase: ApprovalStateMachineTestCase {
    let phone = Data(repeating: 0x31, count: 16)
    let tablet = Data(repeating: 0x32, count: 16)

    /// Adds an approver the way the App does: counter first, then the addition.
    @discardableResult
    func activate(_ machine: BrokerApprovalStateMachine, _ pairingID: Data? = nil,
                  name: String = "Synthetic Phone") throws -> BrokerRemoteApprover {
        let id = pairingID ?? phone
        let generations = try machine.addActiveApprovers([id], revocationCount: machine.activeApproverRevocationCount())
        return BrokerRemoteApprover(pairingID: id, generation: try XCTUnwrap(generations[id]), deviceName: name)
    }

    func remote(
        _ machine: BrokerApprovalStateMachine,
        _ ticket: BrokerApprovalTicket,
        _ operation: BrokerApprovalOperationRequest,
        _ approver: BrokerRemoteApprover,
        _ code: BrokerRemoteDecisionCode,
        ceiling: TimeInterval = 0,
        revalidate: () throws -> Void = {}
    ) throws -> BrokerRemoteDecisionOutcome {
        try machine.decideRemotely(requestID: ticket.requestID, capability: ticket.capability,
                                   operationRequest: operation, approver: approver, code: code,
                                   durationCeiling: ceiling, revalidate: revalidate)
    }

    func state(_ machine: BrokerApprovalStateMachine, _ ticket: BrokerApprovalTicket) throws -> BrokerRequestState {
        try machine.status(requestID: ticket.requestID, capability: ticket.capability)
    }

    func consumeForRuntime(
        _ machine: BrokerApprovalStateMachine, _ ticket: BrokerApprovalTicket, _ operation: BrokerApprovalOperationRequest
    ) throws -> BrokerRuntimeReadAuthorization {
        try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
        ]))
    }
}
