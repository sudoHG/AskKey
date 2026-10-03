import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

public struct GrokCLIConnectResult: Equatable, Sendable {
    public var connected: Bool
    public var reason: String
    public var diff: String
    public var listJSON: String
    public var doctorJSON: String
    public var helperVersion: String
}
