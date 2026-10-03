import Darwin
import Foundation

/// Previews and atomically manages Ask Key's Codex discovery hook.
///
/// This type owns only `hooks.json`. Codex trust state and `config.toml` are
/// managed by their respective integration boundaries.
public final class CodexDiscoveryHookConfiguration: @unchecked Sendable {
    public static let maximumHooksBytes = 1_048_576

    static let expectedMatcher = "^(Bash|mcp__askkey__list_credentials)$"
    static let expectedServer = "askkey"
    static let expectedTool = "credential_discovery_guard"

    let hooksURL: URL
    let backupDirectory: URL
    let mutationLock = NSLock()

    public init(hooksURL: URL, backupDirectory: URL) {
        self.hooksURL = hooksURL
        self.backupDirectory = backupDirectory
    }

}
