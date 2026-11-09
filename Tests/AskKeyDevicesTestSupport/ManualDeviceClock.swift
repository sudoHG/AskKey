import AskKeyDevices
import Foundation

/// A clock that moves only when a test moves it.
public final class ManualDeviceClock: DeviceClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    public func now() -> Date { lock.withLock { current } }

    public func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}
