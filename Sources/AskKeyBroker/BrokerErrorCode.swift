import Foundation

public enum BrokerErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedVersion = "unsupported_version"
    case methodNotAllowed = "method_not_allowed"
    case invalidRequest = "invalid_request"
    case requestNotFound = "request_not_found"
    case resourceExhausted = "resource_exhausted"
    case deadlineExceeded = "deadline_exceeded"
    case responseTooLarge = "response_too_large"
    case internalError = "internal_error"
    case agentAccessPaused = "agent_access_paused"
    case requestRejected = "request_rejected"
}
