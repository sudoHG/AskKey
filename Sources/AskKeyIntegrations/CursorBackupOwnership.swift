import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

final class CursorBackupOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var generationID: UUID?

    func set(_ generationID: UUID) {
        lock.withLock { self.generationID = generationID }
    }

    func matches(_ generationID: UUID) -> Bool {
        lock.withLock { self.generationID == generationID }
    }
}
