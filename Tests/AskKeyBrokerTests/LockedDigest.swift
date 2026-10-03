import Foundation
@testable import AskKeyBroker

final class LockedDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) { storedValue = value }

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); storedValue = newValue; lock.unlock() }
    }
}
