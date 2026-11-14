import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import CryptoKit
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Remote approval steps on the device coordinator harness (ADR 0014). Every
/// credential, name and value is synthetic.
@MainActor
extension DeviceCoordinatorHarness {
    nonisolated static let credentialName = "SYNTHETIC_TOKEN"

    var vault: Vault { library.vault }

    /// Pairs the simulated iPhone and turns its approval on through the sheet.
    func pairApprover() async throws {
        try await pairPhone()
        try await enableApprover(phone)
        try addCredential()
    }

    /// Pairs another simulated iPhone through the whole pairing flow.
    func pair(_ other: SimulatedPairingPhone, name: String) async throws {
        await coordinator.startPairing()
        guard case .showingQRCode(let text, _) = coordinator.pairing else { throw SyntheticRemoteFailure() }
        try await other.scan(text, name: name)
        await coordinator.refresh()
        try await other.poll()
        await coordinator.refresh()
        guard let code = await other.shownCode() else { throw SyntheticRemoteFailure() }
        await coordinator.enterPairingCode(code)
        await coordinator.confirmPairing()
        try await other.confirm()
        try await other.poll()
        await coordinator.refresh()
        guard case .paired = coordinator.pairing else { throw SyntheticRemoteFailure() }
        await coordinator.cancelPairing()
        try await other.poll()
        await coordinator.refresh()
    }

    /// Opens the approver sheet for `phone`, types the shown code on it and
    /// lets the Mac process the confirmation.
    func enableApprover(_ phone: SimulatedPairingPhone) async throws {
        await coordinator.startApproverConfirmation(for: phone.deviceID)
        let code = try XCTUnwrap(coordinator.approverCode, "the sheet shows a code")
        try await phone.confirmApprover(typing: code.formatted, for: XCTUnwrap(macDeviceID))
        await coordinator.refresh()
        guard case .enabled = coordinator.approverConfirmation else {
            XCTFail("approval is on, not \(String(describing: coordinator.approverConfirmation))")
            throw SyntheticRemoteFailure()
        }
        coordinator.cancelApproverConfirmation()
    }

    func addCredential(name: String = DeviceCoordinatorHarness.credentialName) throws {
        _ = try vault.createTextCredential(.init(name: name, value: "synthetic-value", environmentVariable: name,
                                                 permission: .ask), using: .allow)
    }

    /// An agent's run asks for the credential, which leaves a pending read,
    /// and the App tells the coordinator, as the Broker's observer does.
    @discardableResult
    func submitRead(command: [String] = ["/usr/bin/true", "--synthetic"],
                    credential: String = DeviceCoordinatorHarness.credentialName) throws -> BrokerPendingApproval {
        let run = BrokerTextRunRequest(command: command, credentialNames: [credential], callerName: "Synthetic Agent")
        guard case .approvalRequired = try vault.brokerTextCredentials(for: run, cancellation: .init()) else {
            throw SyntheticRemoteFailure()
        }
        let pending = try XCTUnwrap(vault.approvalRequests.pendingRequests().last)
        coordinator.approvalRequestsChanged()
        return pending
    }

    /// A request submitted to the Broker directly, for shapes a run cannot make.
    @discardableResult
    func submitDirect(_ operation: BrokerApprovalOperation = .read,
                      display: BrokerApprovalOperationRequest.Display? = nil) throws -> BrokerPendingApproval {
        let id = UUID().uuidString
        let request = BrokerApprovalOperationRequest(
            operationID: id, credentialID: id, targetID: id, operation: operation,
            payloadDigest: String(repeating: "a", count: 64), credentialName: "Synthetic", callerName: "Synthetic Agent",
            display: display)
        _ = try vault.approvalRequests.submit(request, trustedCredentialDeadline: .none)
        coordinator.approvalRequestsChanged()
        return try XCTUnwrap(vault.approvalRequests.pendingRequests().last)
    }

    nonisolated static let syntheticDisplay = BrokerApprovalOperationRequest.Display(
        commandLine: "/usr/bin/true --synthetic", workingDirectory: "~/synthetic", executableBasename: "true",
        environmentVariables: ["SYNTHETIC_TOKEN"], temporaryFileVariables: [])

    /// Waits until the Mac has sent `count` approval requests in all.
    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil({ macSent(.approvalRequest).count >= count }, file: file, line: line)
        try await waitUntil({ coordinator.remoteRequests.values.allSatisfy { $0.phase != .sending } }, file: file, line: line)
    }

    /// The phone fetches its inbox and returns the requests it verified.
    func phoneRequests(_ phone: SimulatedPairingPhone? = nil) async throws -> [VerifiedApprovalMessage] {
        let phone = phone ?? self.phone
        try await phone.poll()
        return phone.requests
    }

    func phoneClosed(_ phone: SimulatedPairingPhone? = nil) async throws -> [ApprovalClosed] {
        let phone = phone ?? self.phone
        try await waitUntil { macSentClosedSettled }
        try await phone.poll()
        return phone.closedMessages.compactMap { message in
            if case .closed(let closed) = message.message { return closed }
            return nil
        }
    }

    var macSentClosedSettled: Bool { coordinator.closedMessages.values.allSatisfy { $0.retryAt != nil } }

    /// The Mac fetches the known records, then lets the decisions' work finish.
    func macFetches() async throws {
        coordinator.nextKnownRecordFetch = nil
        await coordinator.remoteApprovalTick()
        try await waitUntil { coordinator.remoteRequests.values.allSatisfy { $0.applying == 0 } }
    }

    func state(_ pending: BrokerPendingApproval) throws -> BrokerRequestState {
        try vault.approvalRequests.status(requestID: pending.requestID, capability: pending.capability)
    }

    func entries(_ pending: BrokerPendingApproval) -> [OutstandingRemoteRequest] {
        coordinator.remoteRequests[pending.requestID]?.entries ?? []
    }

    func generation(of phone: SimulatedPairingPhone) throws -> UInt64? {
        let row = try XCTUnwrap(coordinator.devices.first { $0.id == phone.deviceID })
        return vault.approvalRequests.activeApproverGeneration(pairingID: row.pairingID.rawValue)
    }

    /// Seals a message from `phone` to the Mac with any payload and message
    /// ID, signed with the phone's message key, as a buggy or replaying
    /// approver could.
    func phoneSeal(_ phone: SimulatedPairingPhone, kind: MessageKind, payload: Data,
                   messageID: MessageID = .random()) async throws -> DeviceEnvelope {
        let devices = try await phone.pairedDevices()
        let mac = try XCTUnwrap(devices.first)
        let sentAt = UnixTime.seconds(clock.now())
        return try MessageCodec.seal(kind: kind, payload: payload, identity: phone.identity, recipient: mac.deviceID,
                                     recipientKey: mac.card.agreementPublicKey, preSharedKey: nil, sentAt: sentAt,
                                     expiresAt: sentAt + 600, messageID: messageID).envelope
    }

    /// A decision payload the phone signs over `digest`, whatever was offered.
    func signedDecision(_ phone: SimulatedPairingPhone, code: ApprovalDecisionCode, ceiling: UInt64,
                        digest: Data) async throws -> Data {
        let devices = try await phone.pairedDevices()
        let mac = try XCTUnwrap(devices.first)
        let statement = ApprovalDecision.statement(approver: phone.deviceID, requester: mac.deviceID,
                                                   pairingID: mac.pairingID, requestDigest: digest, code: code,
                                                   durationCeiling: ceiling)
        let slot = code == .deny ? Data(count: 64) : try await phone.identity.signWithApprovalKey(statement, reason: "")
        return ApprovalDecision.encode(pairingID: mac.pairingID, requestDigest: digest, code: code,
                                       durationCeiling: ceiling, slot: slot)
    }

    var refusals: [DeviceMessageRefusal] {
        script.loggedEvents.compactMap { event in
            if case .messageRefused(let refusal) = event { return refusal }
            return nil
        }
    }
}

extension VerifiedApprovalMessage {
    var approvalRequest: ApprovalRequest? {
        if case .request(let request) = message { return request }
        return nil
    }
}

struct SyntheticRemoteFailure: Error {}
