import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public struct CodexMCPCommand: Sendable {
    public var status: @Sendable () -> CodexMCPCLIStatus
    public var addAskKey: @Sendable (URL, URL) throws -> Void

    public init(
        status: @escaping @Sendable () -> CodexMCPCLIStatus,
        addAskKey: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.status = status
        self.addAskKey = addAskKey
    }

    public static let missing = CodexMCPCommand(status: { .missing }, addAskKey: { _, _ in })
}
