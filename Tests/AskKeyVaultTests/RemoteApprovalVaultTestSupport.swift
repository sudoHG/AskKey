import AskKeyBroker
import AskKeyDevices
import AskKeyDevicesTestSupport
import Foundation
import XCTest
@testable import AskKeyVault

/// A real temporary library with one Ask credential, a pending read, and a
/// paired iPhone on the Mac's list (ADR 0014). Every value is synthetic.
class RemoteApprovalVaultTestCase: XCTestCase {
    struct Pending {
        let approval: BrokerPendingApproval
        let run: BrokerTextRunRequest
    }

    func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        try library.vault.beginManagementSession(using: .allow)
        _ = try library.vault.createTextCredential(.init(name: "ASK", value: "synthetic", environmentVariable: "TOKEN",
                                                         permission: .ask), using: .allow)
        return library
    }

    /// A second process on the same library and keychain items, so a policy
    /// change in the first reaches it only through revalidation.
    func makeSecondVault(_ library: AgentAccessPolicyLibrary) throws -> Vault {
        let manager = try FileDeliveryManager(rootURL: library.root.appendingPathComponent("second-deliveries"))
        return Vault(store: try library.store, key: try library.key, policyStore: library.keys, fileDeliveryManager: manager)
    }

    func syntheticDevice(name: String = "Synthetic Phone") throws -> PairedDevice {
        let card = try DeviceCard.make(identity: SoftwareDeviceIdentity(), platform: .iOS,
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let pairingID = try XCTUnwrap(PairingID(rawValue: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })))
        return PairedDevice(card: card, pairingID: pairingID, displayName: name,
                            pairedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    func pair(_ device: PairedDevice, in library: AgentAccessPolicyLibrary) async throws {
        try library.vault.authorizeDevicePairing(with: device.deviceID, using: .allow)
        try await library.vault.pairedDeviceRegistry().apply(.add(device))
    }

    /// The App adds an approver to the Broker's set: counter, list, addition.
    func activate(_ device: PairedDevice, in vault: Vault) throws -> UInt64 {
        let id = device.pairingID.rawValue
        let generations = try vault.approvalRequests.addActiveApprovers(
            [id], revocationCount: vault.approvalRequests.activeApproverRevocationCount())
        return try XCTUnwrap(generations[id])
    }

    func pendingRead(in vault: Vault, operationID: String = UUID().uuidString) throws -> Pending {
        let run = BrokerTextRunRequest(operationID: operationID, command: ["/usr/bin/true"], credentialNames: ["ASK"])
        guard case .approvalRequired = try vault.brokerTextCredentials(for: run, cancellation: .init()) else {
            throw SyntheticPolicyFailure()
        }
        let approval = try XCTUnwrap(vault.approvalRequests.pendingRequests().last)
        return Pending(approval: approval, run: run)
    }

    func decide(
        _ vault: Vault, _ pending: Pending, by device: PairedDevice, generation: UInt64,
        _ code: BrokerRemoteDecisionCode, ceiling: TimeInterval = 0
    ) throws -> BrokerRemoteDecisionOutcome {
        try vault.decideRemoteAgentApproval(
            requestID: pending.approval.requestID, capability: pending.approval.capability,
            operationRequest: pending.approval.request, approver: device.deviceID, pairingID: device.pairingID,
            generation: generation, deviceName: device.displayName, code: code, durationCeiling: ceiling)
    }

    func state(_ vault: Vault, _ pending: Pending) throws -> BrokerRequestState {
        try vault.approvalRequests.status(requestID: pending.approval.requestID, capability: pending.approval.capability)
    }

    func runtimeReadRecords(_ vault: Vault) throws -> [CredentialAccessEvent] {
        try vault.listCredentialAccessRecords().filter { $0.operation == .runtimeRead }
    }
}
