import Foundation

final class BrokerSignalPermit {
    private static let lock = NSLock()
    private let stateLock = NSLock()
    private var released = false

    init() { Self.lock.lock() }

    func release() {
        stateLock.lock()
        guard !released else { stateLock.unlock(); return }
        released = true
        stateLock.unlock()
        Self.lock.unlock()
    }
}
