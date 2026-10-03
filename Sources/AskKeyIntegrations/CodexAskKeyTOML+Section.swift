import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    struct Section {
        var raw: String
        var body: String
        var name: TableName?
        var isArray: Bool
        var newline: String
    }
}
