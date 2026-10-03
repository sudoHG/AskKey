import XCTest
@testable import AskKeyBroker

final class FailedReadBufferRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [BrokerClearedReadBuffer] = []

    func record(_ value: BrokerClearedReadBuffer) {
        condition.lock()
        values.append(value)
        condition.signal()
        condition.unlock()
    }

    func next() throws -> BrokerClearedReadBuffer {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(BrokerLimits.readDeadline + 2)
        while values.isEmpty, condition.wait(until: deadline) {}
        guard !values.isEmpty else { throw BrokerSocketError.noResponse }
        return values.removeFirst()
    }
}
