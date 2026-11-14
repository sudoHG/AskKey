import Foundation

/// A decision code a paired approver may send for a read request (ADR 0014).
/// The group allowance and writes have no code here.
package enum BrokerRemoteDecisionCode: UInt8, Equatable, Sendable {
    case deny = 0
    case allowOnce = 1
    /// A timed allowance for the request's one credential.
    case timedAllowance = 2
}

/// The approver a verified remote decision came from. The pairing ID is an
/// opaque 16-byte value: `AskKeyBroker` does not depend on `AskKeyDevices`.
package struct BrokerRemoteApprover: Equatable, Sendable {
    package let pairingID: Data
    /// The enablement generation the App recorded when it sealed the request.
    package let generation: UInt64
    /// The device's name as the Mac called it when it decided; display only.
    package let deviceName: String

    package init(pairingID: Data, generation: UInt64, deviceName: String) {
        self.pairingID = pairingID
        self.generation = generation
        self.deviceName = deviceName
    }
}

/// What a remote decision did. Nothing changed unless it is `applied`.
package enum BrokerRemoteDecisionOutcome: Equatable, Sendable {
    /// This call moved the request out of pending. `grantedSeconds` is the
    /// timed allowance's length in whole seconds, rounded down; otherwise 0.
    case applied(BrokerRequestState, grantedSeconds: UInt64)
    /// The request had already left pending. `decidedBy` is the pairing ID of
    /// the approver whose remote decision moved it, nil if none did.
    case notPending(BrokerRequestState, decidedBy: Data?)
    /// The approver is not in the active set with the recorded generation.
    case approverInactive
    /// The request is pending, but the decision cannot be applied as signed.
    case notApplicable

    package var movedRequest: Bool {
        if case .applied = self { return true }
        return false
    }
}

package enum BrokerActiveApproverError: Error, Equatable, Sendable {
    /// A pairing ID is not 16 bytes, or appears twice.
    case malformedPairingID
    /// The revocation counter changed after the caller read it; nothing was
    /// added. Read the counter, then the list, and add again.
    case revocationRaced
}
