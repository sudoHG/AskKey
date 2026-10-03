@testable import AskKeyBroker
import Foundation
import Darwin

final class ApprovalWaitRunOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<BrokerTextRunResult, Error>?

    func record(_ result: Result<BrokerTextRunResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.result = result
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .failure(let error)? = result else { return false }
        return error is BrokerCancellationError
    }

    var socketError: BrokerSocketError? {
        lock.lock(); defer { lock.unlock() }
        guard case .failure(let error)? = result else { return nil }
        return error as? BrokerSocketError
    }
}
