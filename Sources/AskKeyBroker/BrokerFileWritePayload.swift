import Foundation

public enum BrokerFileWritePayload: Codable, Equatable, Sendable {
    case componentFrozen(BrokerComponentFileReference)
    case uploadCancelled
    case upload(BrokerFileUploadTicket)
    case chunkAccepted(nextOffset: Int)
    case approval(BrokerApprovalTicket)
}
