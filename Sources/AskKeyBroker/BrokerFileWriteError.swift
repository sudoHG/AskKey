import CryptoKit
import Darwin
import Foundation

public enum BrokerFileWriteError: Error, Equatable {
    case invalidRequest
    case invalidCapability
    case outOfOrderChunk
    case tooLarge
    case capacityReached
    case truncatedUpload
    case alreadyFrozen
    case requestNotFound
    case digestMismatch
    case targetChanged
    case authenticationFailed
    case outcomeUnknown
    case stagingFailed
    case stagingNotADirectory
    case stagingPermissionDenied
}
