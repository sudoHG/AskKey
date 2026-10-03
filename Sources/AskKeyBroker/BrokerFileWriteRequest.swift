import Foundation

public enum BrokerFileWriteRequest: Codable, Equatable, Sendable {
    case beginComponent(BrokerComponentUploadBeginRequest)
    case freezeComponent(BrokerFileWriteFreezeRequest)
    case cancelUpload(BrokerFileWriteFreezeRequest)
    case begin(BrokerFileWriteBeginRequest)
    case append(BrokerFileWriteChunkRequest)
    case freeze(BrokerFileWriteFreezeRequest)
}
