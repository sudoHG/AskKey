import Foundation

public enum BrokerSocketError: Error, LocalizedError, Equatable {
    case pathTooLong
    case notRunning
    case noResponse
    case frameTooLarge
    case responseTooLarge
    case malformedResponse
    case brokerFailure(BrokerErrorCode)
    case systemError(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "The Broker socket path is too long."
        case .notRunning: return "The Ask Key Broker is not running."
        case .noResponse: return "The Ask Key Broker closed the connection without responding."
        case .frameTooLarge: return "The Broker request exceeds its fixed size limit."
        case .responseTooLarge: return "The Broker response exceeds its fixed size limit."
        case .malformedResponse: return "The Ask Key Broker returned a malformed response."
        case .brokerFailure(let code): return "The Ask Key Broker rejected the request (\(code.rawValue))."
        case let .systemError(call, code): return "Socket \(call) failed (errno \(code))."
        }
    }
}
