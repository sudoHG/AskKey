import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var bytes: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
