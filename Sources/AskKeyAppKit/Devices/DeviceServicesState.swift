import AskKeyDevices
import Foundation

/// Whether the Devices section can pair, and if not, why (ADR 0013 → Mac App).
package enum DeviceServicesAvailability: Equatable, Sendable {
    /// This build has no CloudKit configured: there is no Devices section
    /// and no CloudKit object exists.
    case notConfigured
    case loading
    /// Pairing is available; `DeviceCoordinator.hasIdentity` tells whether
    /// this Mac already has its device identity.
    case ready
    /// This Mac has no Secure Enclave, so it cannot pair.
    case secureEnclaveUnavailable
    /// A stored key no longer works, for example after Migration Assistant.
    /// Offer `resetIdentity()`, which deletes the keys and the list.
    case identityUnusable
    /// The stored paired-device list failed authentication. It is refused,
    /// not repaired; offer `resetIdentity()`.
    case listRefused
    /// The library is not open, a local erase is pending, or the keychain
    /// refused the device items (`DeviceCoordinator.storageFailureMessage`).
    case storageUnavailable
}

/// The iCloud account as the Devices section explains it. In every state
/// but `available`, every paired device shows as unreachable and the list is
/// kept (ADR 0013 → Removal and account changes).
package enum DeviceAccountStatus: Equatable, Sendable {
    /// Not checked yet: this Mac has no identity, so it makes no CloudKit request.
    case unknown
    case available
    /// Another account than the one the devices were paired in, including a
    /// change while the App was not running. The person removes the devices
    /// or signs back in; pairing waits until the list is empty.
    case accountChanged
    case noAccount
    case restricted
    case temporarilyUnavailable

    var isSignedIn: Bool { self == .available || self == .accountChanged }
}

/// How a paired device is shown.
package enum DeviceReachability: Equatable, Sendable {
    /// No delivery check between the two devices has succeeded since pairing,
    /// so a pairing that only one side completed shows.
    case notReachedYet
    case reached(at: Date)
    /// The account is not available, changed, or the device's inbox is gone.
    case unreachable
}

/// One row of the paired-device list. Platform and name are what the peer
/// said about itself; neither is presented as verified.
package struct PairedDeviceRow: Identifiable, Equatable, Sendable {
    package let id: DeviceID
    package let pairingID: PairingID
    package let displayName: String
    package let platform: DevicePlatform
    package let pairedAt: Date
    package let lastDeliveryCheck: DeliveryCheckResult?
    package let reachability: DeviceReachability
    /// Whether this device may decide agent requests (ADR 0014 → Approvers).
    package var isApprover = false
}

/// What the pairing sheet shows. The Mac never shows the pairing code: no
/// case carries it, and nothing shows whether the iPhone confirmed until the
/// person confirms on the Mac.
package enum PairingSheetState: Equatable, Sendable {
    /// Creating the identity, the inbox and the session.
    case preparing
    /// Show this QR code until `expiresAt`, with the instruction to scan it
    /// only from this window.
    case showingQRCode(text: String, expiresAt: Date)
    /// The QR code is hidden: a request was frozen and challenged, and the
    /// iPhone's verified reveal has not arrived. Tell the person that if the
    /// iPhone has shown a code for more than about 10 seconds while the Mac
    /// still waits, they should cancel and pair again.
    case waitingForIPhone(peer: PairingPeer, since: Date)
    /// The reveal was verified: show the six-digit entry field and the
    /// instruction to enter only the code on the iPhone's pairing screen.
    case enteringCode(peer: PairingPeer, attemptsRemaining: Int)
    /// The entered code was accepted; confirming asks for system
    /// authentication, again after a cancelled or failed one.
    case codeAccepted(peer: PairingPeer)
    /// The Mac confirmed; the iPhone's confirmation has not arrived.
    case waitingForIPhoneConfirmation(peer: PairingPeer)
    case paired(peer: PairingPeer)
    case ended(PairingEndReason)
    /// The session could not start.
    case failed(PairingStartFailure)

    var isActive: Bool {
        switch self {
        case .preparing, .showingQRCode, .waitingForIPhone, .enteringCode, .codeAccepted, .waitingForIPhoneConfirmation:
            return true
        case .paired, .ended, .failed:
            return false
        }
    }
}

package enum PairingStartFailure: Equatable, Sendable {
    /// Pairing needs the management session.
    case managementRequired
    case secureEnclaveUnavailable
    /// iCloud is signed out, restricted, unavailable, or changed while
    /// devices from the other account are still listed.
    case accountUnavailable(DeviceAccountStatus)
    /// The inbox or its subscriptions could not be prepared.
    case iCloudUnavailable
    case identityUnusable
    case storageUnavailable
    case keyCreationFailed
}

/// Feedback for the person's last pairing action.
package enum PairingFeedback: Equatable, Sendable {
    /// Not six digits once white space is removed; not counted as an attempt.
    case invalidCodeFormat
    case wrongCode(attemptsRemaining: Int)
    /// Cancelled; not an attempt, and confirming again needs no new entry.
    case authenticationCancelled
    case authenticationFailed
}

/// A Devices action that did not complete.
package enum DeviceActionIssue: Equatable, Sendable {
    case managementRequired
    case deviceNotFound
    case deliveryCheckFailed
    /// The device was removed here, but the unpair notice could not be sent.
    case unpairNoticeNotSent
    case actionFailed
}
