import Foundation

extension BrokerRequest {
    static func decodeClearingFrame(_ frame: inout Data) -> BrokerRequest? {
        defer { frame.resetBytes(in: frame.startIndex..<frame.endIndex) }
        return try? JSONDecoder().decode(BrokerRequest.self, from: frame)
    }
}
