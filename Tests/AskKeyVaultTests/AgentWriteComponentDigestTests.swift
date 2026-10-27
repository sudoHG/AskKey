import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

/// Stored values stay closed; the card gets explicit intent for each upsert.
final class AgentWriteComponentDigestTests: AgentTextWriteTestSupport {
    private func createReleaseCheck(_ harness: Harness) throws {
        _ = try harness.vault.createBundleCredential(.init(name: "Release Check", components: [
            .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("RELEASE_USER")),
            .init(name: "TOKEN", value: .text("synthetic-token-aaaa"), delivery: .environmentVariable("RELEASE_TOKEN")),
            .init(name: "CERT", value: .file(filename: "cert.pem", bytes: Data("synthetic-certificate".utf8)),
                  delivery: .temporaryFile("RELEASE_CERT_FILE")),
        ], usageInstructions: "Use for release checks.", groupName: "Release Tools", permission: .ask), using: .allow)
    }

    func testRotatingOneComponentLeavesOldSizesAndDigestsUnknown() throws {
        let harness = try makeHarness { _ in true }
        try createReleaseCheck(harness)
        let rotated = "synthetic-token-bbbb"
        let request = AgentTextWriteRequest(operationID: "rotate-token", action: .modifyBundle(name: "Release Check", changes: [
            .upsert(.init(name: "TOKEN", value: .text(rotated), delivery: .environmentVariable("RELEASE_TOKEN"))),
        ]))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)

        XCTAssertEqual(summary.before.map(\.name), ["USER", "TOKEN", "CERT"])
        XCTAssertEqual(summary.after.map(\.name), ["USER", "TOKEN", "CERT"])
        XCTAssertEqual(summary.before.map(\.byteCount), [nil, nil, nil])
        XCTAssertEqual(summary.after.map(\.byteCount), [nil, rotated.utf8.count, nil])
        XCTAssertEqual(summary.before.map(\.delivery), summary.after.map(\.delivery))
        XCTAssertNil(summary.beforeDigest)
        XCTAssertNotNil(summary.afterDigest)

        let before = summary.before.map(\.valueDigest)
        let after = summary.after.map(\.valueDigest)
        XCTAssertEqual(before, [nil, nil, nil])
        XCTAssertNil(after[0])
        XCTAssertEqual(after[1]?.count, 64)
        XCTAssertNil(after[2])
        XCTAssertEqual(summary.after.map(\.valueChanged), [false, true, false])
        XCTAssertEqual(summary.before.map(\.masked), [nil, nil, nil])

        // Keyed by the vault, so a leaked digest would not confirm a guessed value.
        let plain = SHA256.hash(data: Data(rotated.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(after.contains(plain))
        // The Broker reply carries the ticket only.
        let reply = try encoded(BrokerResponse.success(.textWriteRequest(.submitted(ticket))))
        for digest in (before + after).compactMap({ $0 }) {
            XCTAssertFalse(reply.contains(digest))
        }
    }

    func testResendingSameValueStillMarksAnUpsertAndKeepsProposedDigestStable() throws {
        let harness = try makeHarness { _ in true }
        try createReleaseCheck(harness)
        func summary(_ operationID: String, delivery: BrokerComponentDelivery) throws -> BrokerCredentialWriteSummary {
            let request = AgentTextWriteRequest(operationID: operationID, action: .modifyBundle(name: "Release Check", changes: [
                .upsert(.init(name: "USER", value: .text("synthetic-user"), delivery: delivery)),
            ]))
            let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
            return try harness.vault.frozenAgentWriteSummary(operationID: operationID,
                requestID: ticket.requestID, capability: ticket.capability)
        }
        let same = try summary("same-user", delivery: .environmentVariable("RELEASE_USER"))
        let moved = try summary("moved-user", delivery: .environmentVariable("RELEASE_LOGIN"))
        XCTAssertEqual(same.before.map(\.valueDigest), [nil, nil, nil])
        XCTAssertEqual(same.after.map(\.valueDigest), moved.after.map(\.valueDigest))
        XCTAssertEqual(same.after.map(\.valueChanged), [true, false, false])
        XCTAssertEqual(moved.after.map(\.valueChanged), [true, false, false])
        XCTAssertNotEqual(moved.before[0].delivery, moved.after[0].delivery)
    }
}
