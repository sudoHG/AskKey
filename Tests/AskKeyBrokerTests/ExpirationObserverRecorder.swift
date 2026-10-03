import XCTest
@testable import AskKeyBroker

final class ExpirationObserverRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let expired: XCTestExpectation
    private var countStorage: [Int] = []
    private var notificationStorage: [BrokerPrivacyNotification] = []
    private var didFulfillExpiry = false

    init(expired: XCTestExpectation) {
        self.expired = expired
    }

    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }

    var notifications: [BrokerPrivacyNotification] {
        lock.lock(); defer { lock.unlock() }
        return notificationStorage
    }

    func record(count: Int) {
        lock.lock()
        countStorage.append(count)
        let shouldFulfill = count == 0 && !didFulfillExpiry
        if shouldFulfill { didFulfillExpiry = true }
        lock.unlock()
        if shouldFulfill { expired.fulfill() }
    }

    func record(notification: BrokerPrivacyNotification) {
        lock.lock(); defer { lock.unlock() }
        notificationStorage.append(notification)
    }
}
