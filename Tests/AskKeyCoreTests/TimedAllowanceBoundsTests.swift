import CryptoKit
import Foundation
import XCTest
@testable import AskKeyBroker
@testable import AskKeyCore

final class TimedAllowanceBoundsTests: XCTestCase {
    func testOversizedTimedAllowanceMinutesDoNotCrashAndFallBackToThirtyMinutes() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let machine = BrokerApprovalStateMachine(
            clock: { start },
            authenticate: { _ in true }
        )
        let vault = try makeVault(approvalRequests: machine)

        vault.updateDefaultTimedAllowanceMinutes(.max)

        let first = try machine.submit(request(operationID: "first"), now: start)
        XCTAssertEqual(
            try machine.decide(
                requestID: first.requestID,
                capability: first.capability,
                decision: .timedAllow(duration: nil),
                now: start
            ).state,
            .approved
        )
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "still-open"),
                now: start.addingTimeInterval(1_799)
            ).state,
            .approved
        )
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "after-default-window"),
                now: start.addingTimeInterval(1_800)
            ).state,
            .pending
        )
    }

    private func makeVault(
        approvalRequests: BrokerApprovalStateMachine
    ) throws -> Vault {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyTimedAllowance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        return Vault(
            store: store,
            key: VaultCrypto.generateKey(),
            approvalRequests: approvalRequests
        )
    }

    private func request(operationID: String) -> BrokerApprovalOperationRequest {
        .init(
            operationID: operationID,
            credentialID: "credential-1",
            targetID: "credential-1",
            operation: .read,
            payloadDigest: String(repeating: "a", count: 64)
        )
    }
}
