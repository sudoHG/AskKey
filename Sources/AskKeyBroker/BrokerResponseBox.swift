import Foundation

final class BrokerResponseBox {
    private let lock = NSLock()
    private var value: BrokerResponse?

    func set(_ response: BrokerResponse) {
        lock.lock(); defer { lock.unlock() }
        value = response
    }

    func get() -> BrokerResponse? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
