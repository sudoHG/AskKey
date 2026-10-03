import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

public struct CursorMCPConnectionStatus: Equatable, Sendable {
    public let connected: Bool
    public let configReady: Bool
    public let helperReady: Bool
    public let protocolReady: Bool
    public let brokerHealthy: Bool
}
