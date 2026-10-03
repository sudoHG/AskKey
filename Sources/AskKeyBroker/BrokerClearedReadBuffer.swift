import Foundation

struct BrokerClearedReadBuffer: Sendable {
    let buffer: Data
    let bytesRead: Int
    let failure: BrokerClearedReadFailure
}
