import Foundation

enum BrokerFrameFailure: Equatable {
    case tooLarge
    case incompleteOrTimedOut
}
