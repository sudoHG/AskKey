import Foundation

// Safe: the release flag is lock-guarded and the callback is immutable.
final class BrokerRequestLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private let releaseImpl: () -> Void

    init(release: @escaping () -> Void) {
        releaseImpl = release
    }

    func release() {
        lock.lock()
        guard !isReleased else { lock.unlock(); return }
        isReleased = true
        lock.unlock()
        releaseImpl()
    }
}
