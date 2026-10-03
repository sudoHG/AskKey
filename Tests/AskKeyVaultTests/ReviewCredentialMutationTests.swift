import XCTest
import Foundation
import CryptoKit
import AskKeyBroker
@testable import AskKeyVault

final class ReviewCredentialMutationTests: XCTestCase {
    func testDeletingGroupInvalidatesFrozenAgentChangeAndCannotResurrectGroup() throws {
        let fixture = try Fixture()
        let credential = try fixture.vault.createBundleCredential(
            .init(name: "Synthetic", components: [.init(name: "TOKEN", value: .text("old"))], groupName: "Deleted"),
            using: .allow
        )
        let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: .modifyBundle(
            name: credential.name, changes: [.upsert(.init(name: "TOKEN", value: .text("new"), delivery: .environmentVariable("TOKEN")))]
        ))
        guard case .submitted(let pending) = try fixture.vault.requestAgentTextWrite(request) else {
            return XCTFail("Expected a frozen pending change")
        }

        try fixture.vault.deleteCredentialGroup("Deleted", using: .allow)

        XCTAssertEqual(try fixture.approvals.status(requestID: pending.requestID, capability: pending.capability), .cancelled)
        XCTAssertThrowsError(try fixture.approvals.decide(requestID: pending.requestID, capability: pending.capability, decision: .once))
        XCTAssertThrowsError(try fixture.vault.commitAgentTextWrite(request, requestID: pending.requestID, capability: pending.capability))
        XCTAssertEqual(try fixture.vault.listCredentialGroups(), [])
        XCTAssertNil(try fixture.vault.listTextCredentials().first?.groupName)
        XCTAssertEqual(try fixture.vault.revealTextCredential(id: credential.id, using: .allow).components.first?.value, .text("old"))
    }
}

private final class Fixture {
    let directory: URL
    let store: VaultStore
    let approvals: BrokerApprovalStateMachine
    let vault: Vault

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyReviewMutation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        store = try VaultStore(path: directory.appendingPathComponent("synthetic.db").path)
        approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        vault = Vault(store: store, key: SymmetricKey(size: .bits256), approvalRequests: approvals,
                      fileDeliveryManager: try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries")))
        try vault.beginManagementSession(using: .allow)
    }

    deinit {
        try? store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
