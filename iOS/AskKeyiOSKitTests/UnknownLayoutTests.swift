@testable import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// A request this app cannot read shows nothing (#314 acceptance 4); the
/// Mac's own prompt still works and the request expires there.
@MainActor
final class UnknownLayoutTests: XCTestCase {
    func testARequestWithAnUnknownLayoutVersionIsRefused() async throws {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        await world.approveMac()
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sealRequest()
        var payload = sealed.request.encoded
        // The layout version follows the 16-byte pairing ID.
        payload[payload.startIndex + PairingID.byteCount] = 2
        let entry = try await world.phoneEntry()
        let sentAt = UnixTime.seconds(world.macClock.now())
        let forged = try MessageCodec.seal(kind: .approvalRequest, payload: payload, identity: world.macIdentity,
                                           recipient: entry.deviceID, recipientKey: entry.card.agreementPublicKey,
                                           preSharedKey: nil, sentAt: sentAt, expiresAt: sentAt + 600)
        try await world.deliver(forged.envelope)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertTrue(world.cloud.records(in: phoneID).isEmpty, "refused and deleted")
        XCTAssertTrue(world.cloud.sent(.approvalReceipt, from: phoneID).isEmpty)

        try await world.deliver(sealed.sealed.envelope)
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1, "the same request in layout 1 shows")
    }
}
