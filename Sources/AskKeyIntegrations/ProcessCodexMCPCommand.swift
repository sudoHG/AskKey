import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum ProcessCodexMCPCommand {
    public static func make(executable: URL) -> CodexMCPCommand {
        CodexMCPCommand(
            status: {
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return .missing
                }
                guard let versionOutput = try? runProcess(
                    executable: executable,
                    arguments: ["--version"],
                    environment: ProcessInfo.processInfo.environment
                ) else {
                    return .unknown(version: nil)
                }
                let version = codexVersion(in: versionOutput)
                guard let version, CodexUserMCP.allowsOfficialCLI(version) else {
                    return .unknown(
                        version: version ?? versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                guard (try? runProcess(
                    executable: executable,
                    arguments: ["mcp", "add", "--help"],
                    environment: ProcessInfo.processInfo.environment
                )) != nil else {
                    return .unknown(version: version)
                }
                return .supported(version: version)
            },
            addAskKey: { helper, config in
                let codexHome = config.deletingLastPathComponent()
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = codexHome.path
                environment["HOME"] = codexHome.deletingLastPathComponent().path
                _ = try runProcess(
                    executable: executable,
                    arguments: ["mcp", "add", CodexUserMCP.serverName, "--", helper.path, "mcp"],
                    environment: environment
                )
            }
        )
    }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

private func codexVersion(in text: String) -> String? {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    // Keep the whole version token: stripping a suffix could authorize a prerelease.
    if tokens.count == 1 {
        return String(tokens[0])
    }
    guard tokens.count == 2, tokens[0] == "codex-cli" else { return nil }
    return String(tokens[1])
}
