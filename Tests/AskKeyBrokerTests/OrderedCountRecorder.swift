import XCTest
@testable import AskKeyBroker

final class OrderedCountRecorder: @unchecked Sendable {
    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ count: Int) {
        if count == 1 {
            firstEntered.signal()
            releaseFirst.wait()
        }
        if count == 2 { secondEntered.signal() }
        lock.lock(); defer { lock.unlock() }
        storage.append(count)
    }
}
