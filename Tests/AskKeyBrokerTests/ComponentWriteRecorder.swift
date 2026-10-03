@testable import AskKeyBroker
import Foundation
import Darwin

final class ComponentWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: BrokerFileWriteCoordinator
    private var recordedSubmissions: [AgentTextWriteRequest] = []
    private var recordedCommits: [AgentTextWriteRequest] = []
    init(coordinator: BrokerFileWriteCoordinator) { self.coordinator = coordinator }
    var submissions: [AgentTextWriteRequest] { lock.lock(); defer { lock.unlock() }; return recordedSubmissions }
    var commits: [AgentTextWriteRequest] { lock.lock(); defer { lock.unlock() }; return recordedCommits }
    func submit(_ request: AgentTextWriteRequest) throws -> AgentTextWriteRequestOutcome {
        for reference in request.componentFileReferences {
            _ = try coordinator.resolveComponent(reference, operationID: request.operationID)
        }
        lock.lock(); defer { lock.unlock() }
        recordedSubmissions.append(request)
        return .submitted(.init(operationID: request.operationID, requestID: "request-" + request.operationID,
            capability: "synthetic-approval-capability", state: .pending, retryCount: 0))
    }
    func commit(_ request: AgentTextWriteRequest, requestID: String, capability: String) throws -> AgentTextWriteResult {
        guard requestID == "request-" + request.operationID, capability == "synthetic-approval-capability" else {
            throw BrokerApprovalError.requestNotFound
        }
        lock.lock(); defer { lock.unlock() }
        recordedCommits.append(request)
        return .init(operationID: request.operationID, credentialID: "synthetic-credential-id")
    }
}
