import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public final class CodexUserMCPAdapter: @unchecked Sendable {
    public static let maximumConfigBytes = 1_048_576

    public let configURL: URL
    public let helperURL: URL
    public let backupDirectory: URL
    public let brokerSocketPath: String
    public let command: CodexMCPCommand
    public let signing: CodexHelperSigning
    public let requiresCredentialDiscovery: Bool
    var lifecycle = CodexApplyLifecycle()
    let mutationLock = NSLock()

    public init(
        configURL: URL,
        helperURL: URL,
        backupDirectory: URL,
        brokerSocketPath: String,
        command: CodexMCPCommand = .missing,
        signing: CodexHelperSigning = .executable,
        requiresCredentialDiscovery: Bool = false
    ) {
        self.configURL = configURL
        self.helperURL = helperURL
        self.backupDirectory = backupDirectory
        self.brokerSocketPath = brokerSocketPath
        self.command = command
        self.signing = signing
        self.requiresCredentialDiscovery = requiresCredentialDiscovery
    }
}
