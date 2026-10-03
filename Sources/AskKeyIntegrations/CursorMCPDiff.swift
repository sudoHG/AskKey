import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

public struct CursorMCPDiff: Equatable, Sendable {
    public let before: String
    public let after: String
}
