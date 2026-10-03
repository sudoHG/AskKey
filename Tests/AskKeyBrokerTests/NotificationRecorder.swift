import XCTest
@testable import AskKeyBroker

final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationStorage: [BrokerPrivacyNotification] = []
    private var countStorage: [Int] = []

    var notifications: [BrokerPrivacyNotification] {
        lock.lock(); defer { lock.unlock() }
        return notificationStorage
    }

    var counts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return countStorage
    }

    func record(notification: BrokerPrivacyNotification) {
        lock.lock(); defer { lock.unlock() }
        notificationStorage.append(notification)
    }

    func record(count: Int) {
        lock.lock(); defer { lock.unlock() }
        countStorage.append(count)
    }
}
