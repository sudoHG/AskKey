import Foundation
@testable import AskKeyBroker

struct Harness {
    let coordinator: BrokerFileWriteCoordinator
    let approvals: BrokerApprovalStateMachine
    let directory: URL
}
