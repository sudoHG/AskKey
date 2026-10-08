import XCTest
import GRDB
import AskKeyBroker
@testable import AskKeyVault

final class AgentGroupTransactionTests: AgentOrganizationTestSupport {
    func testAppCreateAndDeleteHoldOneTransactionAcrossReadMergeWriteAgainstBothAgentWriters() throws {
        for deleting in [false, true] {
            for organization in [false, true] {
                let harness = try makeHarness { _ in true }
                try harness.vault.createCredentialGroup("Keep", using: .allow)
                try harness.vault.createCredentialGroup("Obsolete", using: .allow)
                let batch = organization
                    ? request([.deleteGroup("Obsolete"), .createGroup("Agent")])
                    : AgentTextWriteRequest(operationID: UUID().uuidString, action: .createBundle(name: "Synthetic",
                        components: [.init(name: "token", value: .text("synthetic-token"), delivery: .none)], group: "Agent"))
                let ticket = try approve(batch, harness: harness)
                let appRead = DispatchSemaphore(value: 0)
                let releaseApp = DispatchSemaphore(value: 0)
                let appFinished = DispatchSemaphore(value: 0)
                let agentStarted = DispatchSemaphore(value: 0)
                let agentFinished = DispatchSemaphore(value: 0)
                let appResults = ConcurrentResults<Void>()
                let agentResults = ConcurrentResults<AgentTextWriteResult>()
                let transactionBoundaries = ConcurrentResults<Bool>()
                try harness.store.db.write { db in
                    var stopped = false
                    var crossedBoundary = false
                    var written = false
                    db.trace(options: [.statement, .profile]) { event in
                        if case .statement(let statement) = event, stopped, !written {
                            if statement.sql == "COMMIT" || statement.sql == "ROLLBACK" { crossedBoundary = true }
                            if statement.sql.hasPrefix("INSERT OR REPLACE INTO config") {
                                written = true
                                transactionBoundaries.append(.success(crossedBoundary))
                            }
                        }
                        guard case .profile(let statement, _) = event, !stopped,
                              statement.sql.hasPrefix("SELECT"), statement.expandedSQL.contains("credential_groups") else { return }
                        stopped = true
                        appRead.signal()
                        _ = releaseApp.wait(timeout: .now() + 5)
                    }
                }
                defer {
                    releaseApp.signal()
                    try? harness.store.db.write { $0.trace(nil) }
                }
                DispatchQueue.global().async {
                    appResults.append(Result {
                        if deleting { try harness.vault.deleteCredentialGroup("Keep", using: .allow) }
                        else { try harness.vault.createCredentialGroup("App", using: .allow) }
                    })
                    appFinished.signal()
                }
                XCTAssertEqual(appRead.wait(timeout: .now() + 2), .success)
                XCTAssertTrue(try harness.vault.agentAccessGate.isPaused(), "App group edits hold the exclusive gate")
                DispatchQueue.global().async {
                    agentStarted.signal()
                    agentResults.append(Result {
                        try harness.vault.commitAgentTextWrite(batch, requestID: ticket.requestID, capability: ticket.capability)
                    })
                    agentFinished.signal()
                }
                XCTAssertEqual(agentStarted.wait(timeout: .now() + 2), .success)
                let reservationBlocked = agentFinished.wait(timeout: .now() + 0.1)
                releaseApp.signal()
                XCTAssertEqual(reservationBlocked, .timedOut, "The App retains the exclusive gate after reading groups")
                XCTAssertEqual(appFinished.wait(timeout: .now() + 5), .success)
                if reservationBlocked == .timedOut { XCTAssertEqual(agentFinished.wait(timeout: .now() + 5), .success) }
                try appResults.values.forEach { try $0.get() }
                XCTAssertEqual(try transactionBoundaries.values.map { try $0.get() }, [false],
                    "No transaction may end between reading and writing the stored group list")
                XCTAssertEqual(agentResults.values.count, 1)
                _ = try agentResults.values.first?.get()
                var expected = ["Agent"]
                if !organization { expected.append("Obsolete") }
                if !deleting { expected += ["App", "Keep"] }
                XCTAssertEqual(try harness.vault.listCredentialGroups(), expected.sorted())
                XCTAssertNotNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
            }
        }
    }
}
