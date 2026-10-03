import Foundation
@testable import AskKeyBroker

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
