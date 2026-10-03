import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

class AgentTextWriteTestSupport: XCTestCase {
    func makeHarness(
        now: @escaping @Sendable () -> Date = { Date() },
        approvalRequests: BrokerApprovalStateMachine? = nil,
        authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAgentWrites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("vault.db")
        let machine = approvalRequests ?? BrokerApprovalStateMachine(
            clock: now,
            authenticate: authenticate
        )
        let store = try VaultStore(path: databaseURL.path)
        let key = VaultCrypto.generateKey()
        let vault = Vault(
            store: store,
            key: key,
            now: now,
            approvalRequests: machine
        )
        try vault.beginManagementSession(using: .allow)
        return Harness(vault: vault, store: store, key: key, databaseURL: databaseURL)
    }
    func encoded<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder().encode(value), encoding: .utf8))
    }
    func submitted(_ outcome: AgentTextWriteRequestOutcome) throws -> AgentTextWriteSubmission {
        guard case let .submitted(submission) = outcome else {
            throw BrokerApprovalError.invalidDecision
        }
        return submission
    }
    struct Harness {
        let vault: Vault
        let store: VaultStore
        let key: SymmetricKey
        let databaseURL: URL

        func databaseBytes() throws -> Data {
            var bytes = Data()
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    bytes.append(try Data(contentsOf: url))
                }
            }
            return bytes
        }
    }
    final class AuthenticationPurposes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [BrokerAuthenticationPurpose] = []
        var values: [BrokerAuthenticationPurpose] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ value: BrokerAuthenticationPurpose) {
            lock.lock(); defer { lock.unlock() }
            storage.append(value)
        }
    }
    final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Date
        var now: Date {
            get {
                lock.lock()
                let value = storage
                lock.unlock()
                return value
            }
            set {
                lock.lock(); defer { lock.unlock() }
                storage = newValue
            }
        }
        init(_ now: Date) { storage = now }
    }
    final class ConcurrentResults<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<Value, Error>] = []
        var values: [Result<Value, Error>] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        func append(_ result: Result<Value, Error>) {
            lock.lock(); defer { lock.unlock() }
            storage.append(result)
        }
    }
}
