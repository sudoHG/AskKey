import AskKeyBroker
import AskKeyDevices
import Foundation

/// Applying a verified decision from a paired approver (ADR 0014 → Verifying
/// and applying a decision). The App has checked the message and its
/// outstanding entry; this entry checks the Mac's own storage and policy, and
/// the Broker's locked transition checks the active-approver set.
extension Vault {
    /// Applies a remote decision on a pending read request.
    ///
    /// For Allow Once and the timed allowance it first re-reads the
    /// paired-device list and requires the sender's entry, with this pairing
    /// ID, to carry the approval flag, then revalidates the agent access policy
    /// as a local decision does and caps the duration at the current setting.
    /// A Deny does neither, because a local Deny never waits for policy I/O
    /// either; the Broker's active-approver check still applies to it.
    ///
    /// Returns `.approverInactive` when the flag is missing or the approver is
    /// not in the active set with `generation` (outcome 5). A throw means the
    /// decision was not applied and nothing changed.
    package func decideRemoteAgentApproval(
        requestID: String,
        capability: String,
        operationRequest: BrokerApprovalOperationRequest,
        approver deviceID: DeviceID,
        pairingID: PairingID,
        generation: UInt64,
        deviceName: String,
        code: BrokerRemoteDecisionCode,
        durationCeiling: TimeInterval
    ) throws -> BrokerRemoteDecisionOutcome {
        let approver = BrokerRemoteApprover(pairingID: pairingID.rawValue, generation: generation, deviceName: deviceName)
        guard code != .deny else {
            return try approvalRequests.decideRemotely(
                requestID: requestID, capability: capability, operationRequest: operationRequest,
                approver: approver, code: .deny, durationCeiling: durationCeiling
            )
        }
        guard try pairedDeviceCarriesApprovalFlag(deviceID, pairingID: pairingID) else { return .approverInactive }
        let policy: AgentAccessPolicy
        do {
            try beginAgentOperation()
            defer { agentAccessGate.endAgentOperation() }
            policy = try savedAgentAccessPolicyState().policy
        }
        // The Broker refuses a timed allowance while timed allowances are off
        // or End Timed Allow on Lock is on, after revalidation adopted the
        // persisted policy. Here a valid ceiling only shrinks; any other
        // reaches the Broker unchanged, which refuses it as not signed so.
        let validCeiling = durationCeiling > 0 && durationCeiling <= 120 * 60
        let ceiling = code == .timedAllowance && validCeiling
            ? min(durationCeiling, TimeInterval(policy.timedAllowanceMinutes * 60))
            : durationCeiling
        return try approvalRequests.decideRemotely(
            requestID: requestID, capability: capability, operationRequest: operationRequest,
            approver: approver, code: code, durationCeiling: ceiling,
            revalidate: {
                try self.agentAccessGate.beginSpawnAuthorization(validating: self.revalidateAgentAccessPolicy,
                                                                 waitForExclusiveChange: 2)
                defer { self.agentAccessGate.endSpawnAuthorization() }
            }
        )
    }

    /// Reads the stored list, not a registry snapshot, under the device lock.
    func pairedDeviceCarriesApprovalFlag(_ deviceID: DeviceID, pairingID: PairingID) throws -> Bool {
        try storedPairedDeviceList().devices.contains {
            $0.deviceID == deviceID && $0.pairingID == pairingID && $0.isApprover
        }
    }
}
