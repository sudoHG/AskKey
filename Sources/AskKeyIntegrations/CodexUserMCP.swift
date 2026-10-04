import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum CodexUserMCP {
    public static let serverName = "askkey"
    public static let bundledHelperPath = OfficialInstallTopology.canonicalHelperPath

    public static func userConfigURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    public static func managedBackupDirectory(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("client-backups", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }

    // Only minor lines whose stable `mcp add/get --json` contract was verified here.
    public static func allowsOfficialCLI(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        let parts = components.compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return parts[0] == 0 && ((42...50).contains(parts[1]) || [151, 153, 154, 156].contains(parts[1]))
    }
}
