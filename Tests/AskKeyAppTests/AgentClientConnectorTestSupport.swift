import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
class AgentClientConnectorTestSupport: AskKeyAppTestCase {
    func codexAdapter(
        root: URL,
        config: URL,
        status: CodexMCPCLIStatus
    ) -> CodexUserMCPAdapter {
        CodexUserMCPAdapter(
            configURL: config,
            helperURL: root.appendingPathComponent("helper"),
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            command: CodexMCPCommand(status: { status }, addAskKey: { _, _ in })
        )
    }

    final class ConnectionAttemptProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        var count: Int { lock.withLock { storage } }
        func record() { lock.withLock { storage += 1 } }
    }

    final class ConnectionConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var highest = 0
        var maximum: Int { lock.withLock { highest } }

        func enter() {
            lock.withLock {
                active += 1
                highest = max(highest, active)
            }
        }

        func leave() { lock.withLock { active -= 1 } }
    }

    final class ConnectionResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []
        var values: [Bool] { lock.withLock { storage } }
        func append(_ value: Bool?) { if let value { lock.withLock { storage.append(value) } } }
    }

    struct UnsafeSendableBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
