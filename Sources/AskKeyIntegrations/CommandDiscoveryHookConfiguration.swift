import Darwin
import Foundation

/// Transactional command-hook configuration for Cursor, Grok and Claude Code.
///
/// The integration supplies `expectedHooks`, so this type does not guess a
/// client matcher or event. Cursor merges its expected event arrays; Grok's
/// dedicated file is owned by Ask Key and rejects unknown existing content.
/// Claude merges individual owned handlers in its shared settings file.
public final class CommandDiscoveryHookConfiguration: @unchecked Sendable {
    public static let maximumHooksBytes = 1_048_576
    public typealias Format = CommandDiscoveryHookFormat

    let hooksURL: URL
    let backupDirectory: URL
    let expectedHooks: Data
    let format: CommandDiscoveryHookFormat
    let lock = NSLock()

    public init(
        hooksURL: URL,
        backupDirectory: URL,
        expectedHooks: Data,
        format: CommandDiscoveryHookFormat
    ) {
        self.hooksURL = hooksURL.standardizedFileURL
        self.backupDirectory = backupDirectory.standardizedFileURL
        self.expectedHooks = expectedHooks
        self.format = format
    }

}

extension CommandDiscoveryHookConfiguration {
    typealias Error = CommandDiscoveryHookConfigurationError

}
