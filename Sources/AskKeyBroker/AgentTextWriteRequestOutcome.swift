import Foundation

public enum AgentTextWriteRequestOutcome: Codable, Equatable, Sendable {
    case submitted(AgentTextWriteSubmission)
    case completed(AgentTextWriteResult)
}
