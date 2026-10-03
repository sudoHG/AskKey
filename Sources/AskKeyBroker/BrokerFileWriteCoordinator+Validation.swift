import CryptoKit
import Darwin
import Foundation

extension BrokerFileWriteCoordinator {
    static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= BrokerLimits.maximumFieldBytes
    }

    static func validFilename(_ value: String) -> Bool {
        validField(value)
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func approvalDigest(session: Session, contentDigest: String) -> String {
        let fields = [
            session.operationID,
            session.credentialID,
            session.targetID,
            session.operation.rawValue,
            session.originalFilename,
            String(session.expectedByteCount),
            session.previousDigest ?? "none",
            contentDigest,
        ]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return digest(Data(canonical.utf8))
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func equalDigest(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return constantTimeEqual(lhs, rhs)
        default: return false
        }
    }

    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }
}
