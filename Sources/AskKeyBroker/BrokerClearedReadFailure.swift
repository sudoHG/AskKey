import Foundation

enum BrokerClearedReadFailure: Equatable, Sendable {
    case deadline
    case endOfFile
    case pollError(Int32)
    case readError(Int32)
}
