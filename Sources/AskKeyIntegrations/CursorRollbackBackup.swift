import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

struct CursorRollbackBackup: Codable {
    let generationID: UUID
    let originalExisted: Bool
    let originalPermissions: UInt16
    let originalBytes: Data
    var replacementDigest: Data
}
