import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

struct CodexRollbackBackup: Codable {
    let originalExisted: Bool
    let originalText: String
    let originalMode: Int
    var replacementDigest: Data?

    var original: CodexOriginalConfig? {
        originalExisted ? CodexOriginalConfig(text: originalText, mode: originalMode) : nil
    }
}
