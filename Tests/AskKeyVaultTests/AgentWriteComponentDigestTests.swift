import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

/// The App-side write summary carries one keyed value digest per component so
/// an approval card can tag each item exactly; it never leaves the App.
final class AgentWriteComponentDigestTests: AgentTextWriteTestSupport {
    private func createReleaseCheck(_ harness: Harness) throws {
        _ = try harness.vault.createBundleCredential(.init(name: "Release Check", components: [
            .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("RELEASE_USER")),
            .init(name: "TOKEN", value: .text("synthetic-token-aaaa"), delivery: .environmentVariable("RELEASE_TOKEN")),
            .init(name: "CERT", value: .file(filename: "cert.pem", bytes: Data("synthetic-certificate".utf8)),
                  delivery: .temporaryFile("RELEASE_CERT_FILE")),
        ], usageInstructions: "Use for release checks.", groupName: "Release Tools", permission: .ask), using: .allow)
    }

    func testRotatingOneSameLengthComponentChangesOnlyItsDigest() throws {
        let harness = try makeHarness { _ in true }
        try createReleaseCheck(harness)
        let rotated = "synthetic-token-bbbb"
        let request = AgentTextWriteRequest(operationID: "rotate-token", action: .modifyBundle(name: "Release Check", changes: [
            .upsert(.init(name: "TOKEN", value: .text(rotated), delivery: .environmentVariable("RELEASE_TOKEN"))),
        ]))
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)

        // Size and delivery alone cannot tell the rotated item apart.
        XCTAssertEqual(summary.before.map(\.name), ["USER", "TOKEN", "CERT"])
        XCTAssertEqual(summary.after.map(\.name), ["USER", "TOKEN", "CERT"])
        XCTAssertEqual(summary.before.map(\.byteCount), summary.after.map(\.byteCount))
        XCTAssertEqual(summary.before.map(\.delivery), summary.after.map(\.delivery))
        XCTAssertNotEqual(summary.beforeDigest, summary.afterDigest)

        let before = summary.before.map(\.valueDigest)
        let after = summary.after.map(\.valueDigest)
        XCTAssertTrue((before + after).allSatisfy { $0?.count == 64 })
        XCTAssertEqual(before[0], after[0], "USER is unchanged")
        XCTAssertNotEqual(before[1], after[1], "TOKEN is replaced")
        XCTAssertEqual(before[2], after[2], "CERT is unchanged")

        // Keyed by the vault, so a leaked digest would not confirm a guessed value.
        let plain = SHA256.hash(data: Data(rotated.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(after.contains(plain))
        // The Broker reply carries the ticket only.
        let reply = try encoded(BrokerResponse.success(.textWriteRequest(.submitted(ticket))))
        for digest in (before + after).compactMap({ $0 }) {
            XCTAssertFalse(reply.contains(digest))
        }
    }

    func testDigestsAreStableAcrossFreezesAndIgnoreDeliveryChanges() throws {
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
        XCTAssertEqual(same.before.map(\.valueDigest), same.after.map(\.valueDigest), "re-sending a value keeps its digest")
        XCTAssertEqual(same.before.map(\.valueDigest), moved.before.map(\.valueDigest), "digests are stable across freezes")
        XCTAssertEqual(moved.before[0].valueDigest, moved.after[0].valueDigest, "a new delivery does not change the value")
        XCTAssertNotEqual(moved.before[0].delivery, moved.after[0].delivery)
    }
}
