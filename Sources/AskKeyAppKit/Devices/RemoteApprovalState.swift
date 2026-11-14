import AskKeyBroker
import AskKeyDevices
import Foundation

/// When one request went to each approver, for the approval panel's details
/// (ADR 0014 → Mac App). It carries no request content.
package struct RemoteApprovalStatus: Equatable, Sendable {
    package struct Approver: Equatable, Sendable {
        package let deviceID: DeviceID
        /// The Mac's name for the device.
        package let displayName: String
        /// When the request was first saved to the device's inbox; nil until then.
        package let sentAt: Date?
        /// When the Mac processed the device's receipt, on the Mac's clock.
        package let deliveredAt: Date?
    }

    package let approvers: [Approver]
}

/// A decision from an approver that moved a request out of pending.
package struct RemoteAppliedDecision: Equatable, Sendable {
    /// The Broker request ID.
    package let requestID: String
    /// The Mac's name for the approver when it decided.
    package let deviceName: String
    package let approved: Bool
}

/// The "Approve agent requests" sheet (ADR 0014 → Approvers). No case
/// carries the approver code; `DeviceCoordinator.approverCode` holds it
/// while the sheet waits for the iPhone.
package enum ApproverConfirmationState: Equatable, Sendable {
    /// System authentication for turning approval on is open.
    case authenticating(device: PairedDeviceRow)
    /// Show the code until `expiresAt`, with what will leave the Mac; the
    /// person types it on that iPhone.
    case waitingForIPhone(device: PairedDeviceRow, expiresAt: Date, attemptsRemaining: Int)
    /// The device is an approver now.
    case enabled(device: PairedDeviceRow)
    case ended(ApproverConfirmationEndReason)

    var isActive: Bool {
        switch self {
        case .authenticating, .waitingForIPhone: return true
        case .enabled, .ended: return false
        }
    }
}

package enum ApproverConfirmationEndReason: Equatable, Sendable {
    /// Turning approval on needs the management session.
    case managementRequired
    /// The device services, the iCloud account or the device's entry are
    /// not available.
    case unavailable
    case authenticationCancelled
    case authenticationFailed
    /// Five minutes passed without a matching confirmation.
    case expired
    /// The selected iPhone sent three wrong codes.
    case tooManyWrongCodes
    /// The code was entered on a different device than the one selected,
    /// named as the Mac calls it.
    case enteredOnOtherDevice(name: String)
    /// The selected device was removed, or paired again, meanwhile.
    case deviceRemoved
    /// The approval flag could not be saved.
    case notSaved
}

/// Holds the process activity that keeps App Nap and idle sleep away while a
/// request needs it (ADR 0014 → When a request goes to an approver).
package struct DeviceProcessActivity {
    package var begin: @MainActor () -> AnyObject
    package var end: @MainActor (AnyObject) -> Void

    package init(begin: @escaping @MainActor () -> AnyObject, end: @escaping @MainActor (AnyObject) -> Void) {
        self.begin = begin
        self.end = end
    }

    package static let system = DeviceProcessActivity(
        begin: {
            ProcessInfo.processInfo.beginActivity(options: .userInitiated,
                                                  reason: "Waiting for a paired device's decision")
        },
        end: { activity in
            if let activity = activity as? NSObjectProtocol { ProcessInfo.processInfo.endActivity(activity) }
        }
    )
}

/// One approver's copy of a request (ADR 0014 → Sending and the return
/// path). It is sealed once; resends use `envelope` unchanged.
struct OutstandingRemoteRequest {
    enum Delivery: Equatable {
        case sending
        case retry(at: Date)
        case sent
    }

    /// The approver's entry when the request was sealed; a closing message
    /// is sealed to it, also after the entry was removed.
    let recipient: PairedDevice
    /// The approver's enablement generation when the request was sealed.
    let generation: UInt64
    let responseID: MessageID
    let receiptID: MessageID
    let requestDigest: Data
    /// What was sealed, after any shortening.
    let offers: ApprovalOffers
    let timedDuration: UInt64
    let envelope: DeviceEnvelope
    let sealedAt: Date
    var delivery: Delivery = .sending
    var sentAt: Date?
    var deliveredAt: Date?
    /// A verified decision consumed this entry; it is being applied.
    var decided = false

    var approverID: DeviceID { recipient.deviceID }
    var pairingID: PairingID { recipient.pairingID }

    func belongs(to device: DeviceID, pairingID: PairingID) -> Bool {
        approverID == device && self.pairingID == pairingID
    }
}

/// A pending Broker request the coordinator has seen.
struct RemoteRequestTrack {
    enum Phase: Equatable {
        /// The screen was unlocked when it appeared: it goes out at
        /// `sendAt` if still pending, or at once if the screen locks first.
        case waiting(sendAt: Date)
        /// Its sealing is being prepared.
        case sending
        /// Sealed for the approvers in `entries`.
        case sent
        /// It was not eligible when checked, and stays on the Mac.
        case stayingOnMac
    }

    let pending: BrokerPendingApproval
    var phase: Phase
    var entries: [OutstandingRemoteRequest] = []
    /// The approver whose own decision moved the request out of pending.
    var appliedBy: PairingID?
    /// Verified decisions being applied; the request closes once they return.
    var applying = 0
    /// The state the request left pending in, once known.
    var ended: BrokerRequestState?

    var requestID: String { pending.requestID }
    var deadline: Date? { pending.expiresAt }
}

/// A closing message waiting to be saved; resent with the same bytes until
/// its transport expiry.
struct PendingClosedMessage {
    let envelope: DeviceEnvelope
    /// Nil while a send is out.
    var retryAt: Date?
}

/// The open approver confirmation (ADR 0014 → Approvers, step 3).
struct ApproverAttempt {
    let device: PairedDeviceRow
    let code: ApproverCode
    let expiresAt: Date
    var attemptsRemaining: Int
    /// A matching confirmation arrived and the flag is being written; any
    /// further confirmation is refused without counting.
    var enabling = false
}
