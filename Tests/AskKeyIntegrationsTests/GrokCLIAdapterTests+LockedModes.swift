import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

extension GrokCLIAdapterTests {
final class LockedModes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int16] = []

    func append(_ mode: Int16) {
        lock.lock()
        storage.append(mode)
        lock.unlock()
    }

    var values: [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
}
