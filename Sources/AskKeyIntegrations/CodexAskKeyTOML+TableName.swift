import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    struct TableName {
        var parts: [String]
        var isAskKey: Bool { parts.count >= 2 && parts[0] == "mcp_servers" && parts[1] == "askkey" }
        var isMCPServersRoot: Bool { parts == ["mcp_servers"] }
    }
}
