import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum CodexMCPCLIStatus: Equatable, Sendable {
    case missing
    case supported(version: String)
    case unknown(version: String?)
}
