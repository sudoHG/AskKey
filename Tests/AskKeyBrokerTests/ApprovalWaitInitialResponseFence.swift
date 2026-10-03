@testable import AskKeyBroker
import Foundation
import Darwin

final class ApprovalWaitInitialResponseFence: @unchecked Sendable {
    private let lock = NSLock()
    private var controlDescriptor: Int32 = -1
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func observeControlDescriptor(_ descriptor: Int32) {
        lock.lock(); defer { lock.unlock() }
        controlDescriptor = descriptor
    }

    func pauseInitialResolution() -> Bool {
        entered.signal()
        return release.wait(timeout: .now() + 10) == .success
    }

    func waitForInitialResolution(timeout: TimeInterval) -> Bool {
        entered.wait(timeout: .now() + timeout) == .success
    }

    func releaseInitialResponse() { release.signal() }

    func waitForForwardedSignal(timeout: TimeInterval) -> Bool {
        lock.lock()
        let descriptor = controlDescriptor
        lock.unlock()
        guard descriptor >= 0 else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            let result = Darwin.poll(&event, 1, remaining)
            if result < 0, errno == EINTR { continue }
            guard result > 0, event.revents & Int16(POLLIN) != 0 else { return false }
            return (Self.availableBytes(descriptor: descriptor) ?? 0) > 0
        }
        return false
    }

    static func availableBytes(descriptor: Int32) -> Int32? {
        var available: CInt = 0
        // Darwin's FIONREAD is _IOR('f', 127, int). Swift cannot import
        // that sizeof-based macro; encode it using sys/ioccom.h's layout.
        let request = UInt(0x40000000 | (MemoryLayout<CInt>.size << 16) | (0x66 << 8) | 127)
        return Darwin.ioctl(descriptor, request, &available) == 0 ? available : nil
    }
}
