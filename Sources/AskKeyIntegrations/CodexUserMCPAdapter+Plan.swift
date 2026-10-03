import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexUserMCPAdapter {

    /// Reads configuration independently of CLI availability or connection health.
    public func hasConfiguration() throws -> Bool {
        try inspectConfigPath()
        return try CodexAskKeyTOML.hasServer(in: readConfig()?.text ?? "", named: "askkey")
    }

    public func preview() throws -> CodexConfigDiff {
        try assertKnownCLI()
        try inspectConfigPath()
        let original = try readConfig()?.text ?? ""
        let after = try CodexAskKeyTOML.upsert(
            original,
            command: helperURL.path,
            args: ["mcp"]
        )
        return CodexConfigDiff(before: original, after: after)
    }

    func assertKnownCLI() throws {
        switch command.status() {
        case .missing:
            return
        case .unknown:
            throw CodexUserMCPError.unknownCodexVersion
        case .supported(let version):
            guard CodexUserMCP.allowsOfficialCLI(version) else {
                throw CodexUserMCPError.unknownCodexVersion
            }
        }
    }
}
