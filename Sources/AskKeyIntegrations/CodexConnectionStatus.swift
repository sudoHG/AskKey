import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum CodexConnectionStatus: Equatable, Sendable {
    case connected
    case notConnected
}
