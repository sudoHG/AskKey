import CryptoKit
import Foundation

enum MigrationSourceFingerprint {
    static func digest(of url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MigrationCommitError.promotedDatabaseInvalid
        }
        var input = Data("AskKey migration source v2\0".utf8)
        append(Data(url.standardizedFileURL.path.utf8), to: &input)
        for suffix in ["", "-wal", "-shm"] {
            append(Data(suffix.utf8), to: &input)
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                input.append(1)
                append(try Data(contentsOf: file, options: .mappedIfSafe), to: &input)
            } else {
                input.append(0)
            }
        }
        return Data(SHA256.hash(data: input))
    }

    private static func append(_ data: Data, to target: inout Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { target.append(contentsOf: $0) }
        target.append(data)
    }
}
