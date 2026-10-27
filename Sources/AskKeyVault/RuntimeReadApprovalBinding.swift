import CryptoKit
import Foundation
import AskKeyBroker

/// App-only binding: the helper supplies the run request, never the projection.
struct RuntimeReadApprovalBinding: Encodable {
    let domain = "AskKey read approval v2"
    let request: BrokerTextRunRequest
    let credentialID: String
    let metadataDigest: String

    init(request: BrokerTextRunRequest, credentialID: String, metadata: CredentialComponentMetadata?) throws {
        self.request = request
        self.credentialID = credentialID
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Unavailable metadata still permits an approval to be denied, but can
        // never pass the post-approval projection check.
        metadataDigest = try metadata.map { Self.digest(try encoder.encode($0)) }
            ?? Self.digest(Data("AskKey unavailable component metadata v1".utf8))
    }

    func payloadDigest() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.digest(try encoder.encode(self))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
