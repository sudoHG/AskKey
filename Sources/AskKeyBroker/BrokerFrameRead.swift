import Foundation

enum BrokerFrameRead {
    case success(Data)
    case failure(BrokerFrameFailure)
    case end
}
