@testable import AskKeyBroker
import Foundation
import Darwin

final class RuntimeEnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []

    var values: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(environment)
    }
}

/// Records the Helper wire boundary. Persistence/approval atomicity is exercised
/// by AuditBrokerBoundaryTests; this fixture does not imitate a Vault.
