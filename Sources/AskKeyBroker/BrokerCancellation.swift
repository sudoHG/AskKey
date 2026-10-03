import Foundation

// Safe: cancellation state and callbacks are protected by the condition lock.
public final class BrokerCancellation: @unchecked Sendable {
    private let condition = NSCondition()
    private var cancelled = false
    private var callbacks: [@Sendable () -> Void] = []

    public init() {}

    public func cancel() {
        condition.lock()
        guard !cancelled else { condition.unlock(); return }
        cancelled = true
        let pendingCallbacks = callbacks
        callbacks.removeAll()
        condition.broadcast()
        condition.unlock()
        pendingCallbacks.forEach { $0() }
    }

    public func onCancel(_ callback: @escaping @Sendable () -> Void) {
        condition.lock()
        if cancelled {
            condition.unlock()
            callback()
        } else {
            callbacks.append(callback)
            condition.unlock()
        }
    }

    public func check() throws {
        condition.lock(); defer { condition.unlock() }
        if cancelled { throw BrokerCancellationError.cancelled }
    }

    public var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }

    public func waitUntilCancelled() {
        condition.lock(); defer { condition.unlock() }
        while !cancelled { condition.wait() }
    }
}
