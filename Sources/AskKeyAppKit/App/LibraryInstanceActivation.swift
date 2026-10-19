import Foundation

@MainActor
final class LibraryInstanceActivation {
    private var activate: (() -> Void)?
    private var pending = false
    private var lastActivation: TimeInterval?
    private let now: () -> TimeInterval

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func request() {
        guard let activate else { pending = true; return }
        let time = now()
        guard lastActivation.map({ time - $0 >= 1 }) ?? true else { return }
        lastActivation = time
        activate()
    }

    func install(_ activate: @escaping () -> Void) {
        self.activate = activate
        if pending {
            pending = false
            request()
        }
    }
}

/// Distributed-notification callbacks need not run on the App's main actor.
final class LibraryInstanceActivationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?

    func receive(_ pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        if pid > 0 { self.pid = pid }
    }

    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return pid
    }
}
