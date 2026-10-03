import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

public struct CursorUserMCPAdapter {
    static let processBackupLock = NSLock()
    public let userConfigURL: URL
    let backupDirectory: URL
    let helperURL: URL
    let signing: CodexHelperSigning
    let brokerSocketPath: String
    let replaceConfig: (URL, URL) throws -> Void
    let removeConfig: (URL) throws -> Void
    let moveConfigExclusively: (URL, URL) throws -> Void
    let removeBackupItem: (URL) throws -> Void
    let backupOwnership = CursorBackupOwnership()

    public init(
        homeDirectory: URL,
        backupDirectory: URL,
        helperURL: URL,
        brokerSocketPath: String,
        signing: CodexHelperSigning = .executable,
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil
    ) {
        self.backupDirectory = backupDirectory
        self.helperURL = helperURL
        self.signing = signing
        self.brokerSocketPath = brokerSocketPath
        self.userConfigURL = homeDirectory.appendingPathComponent(".cursor/mcp.json")
        self.replaceConfig = replaceConfig ?? Self.renameExclusively
        self.removeConfig = removeConfig ?? { try FileManager.default.removeItem(at: $0) }
        self.moveConfigExclusively = moveConfigExclusively ?? Self.renameExclusively
        self.removeBackupItem = removeBackupItem ?? { try FileManager.default.removeItem(at: $0) }
    }
}
