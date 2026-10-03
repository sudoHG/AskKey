import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

struct CursorConfigSnapshot {
    let existed: Bool
    let permissions: mode_t
    let bytes: Data
    let quarantineURL: URL?
}
