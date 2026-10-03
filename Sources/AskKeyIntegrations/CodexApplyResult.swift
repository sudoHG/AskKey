import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public struct CodexApplyResult: Equatable, Sendable {
    public let status: CodexConnectionStatus
    public let diff: CodexConfigDiff
}
