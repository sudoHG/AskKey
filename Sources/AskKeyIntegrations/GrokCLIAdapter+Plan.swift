import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

extension GrokCLIAdapter {
    /// Does not invoke Grok, create a diagnostics home, or write configuration.
    public func hasConfiguration() throws -> Bool {
        try inspectConfigFile()
        let text = try readOriginal().text ?? ""
        _ = try GrokUserTOML.parse(text)
        do {
            return try CodexAskKeyTOML.hasServer(in: text, named: serverName)
        } catch {
            throw GrokCLIAdapterError.invalidConfig
        }
    }

    public func preview() throws -> String {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal().text ?? ""
        try validateUserTOML(original)
        let desired = try GrokUserTOML.upsertStdio(
            in: original,
            serverName: serverName,
            command: helperExecutable.path,
            args: ["mcp"],
            env: helperEnvironment
        )
        return GrokUserTOML.redactedDiff(before: original, after: desired)
    }

}
