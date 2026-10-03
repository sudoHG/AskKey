@testable import AskKeyBroker
import Foundation
import Darwin

final class RuntimeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: BrokerTextRunRequest?

    var request: BrokerTextRunRequest? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ request: BrokerTextRunRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded = request
    }
}
