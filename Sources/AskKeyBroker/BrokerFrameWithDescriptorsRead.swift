import Foundation

enum BrokerFrameWithDescriptorsRead {
    case success(BrokerFrameWithDescriptors)
    case failure(BrokerFrameFailure)
    case end
}
