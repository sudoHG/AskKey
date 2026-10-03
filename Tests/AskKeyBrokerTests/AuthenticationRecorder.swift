import XCTest
@testable import AskKeyBroker

final class AuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BrokerAuthenticationPurpose] = []

    var values: [BrokerAuthenticationPurpose] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func record(_ purpose: BrokerAuthenticationPurpose) {
        lock.lock(); defer { lock.unlock() }
        storage.append(purpose)
    }
}
