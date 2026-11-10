import AskKeyDevices
import Foundation

/// What the pairing sheet shows for one coordinator state (ADR 0013 →
/// Pairing). The state carries no code, so neither does anything here:
/// the sheet never shows the Mac's code. Before the person confirms on the
/// Mac, nothing says whether the iPhone has confirmed.
struct PairingSheetPresentation: Equatable {
    enum Stage: Equatable {
        case preparing
        case qrCode(text: String, expiresAt: Date)
        case waitingForIPhone
        /// The six-digit field. `accepted` once the code matched: the field
        /// takes no further entry and **Confirm** asks for system authentication.
        case codeEntry(accepted: Bool)
        case waitingForIPhoneConfirmation
        case paired
        case ended(canPairAgain: Bool)
        case failed
    }

    let stage: Stage
    let title: String
    let message: String?
    /// The device that scanned the QR code, as it describes itself.
    let peer: PairingPeer?
    /// A warning shown on the subtle warning surface.
    let notice: String?
    /// The result of the person's last action, shown under the field.
    let feedback: String?
    /// A wrong or malformed entry, or a cancelled or failed authentication.
    let feedbackIsWarning: Bool

    init(state: PairingSheetState, feedback: PairingFeedback?, isAuthenticating: Bool) {
        var peer: PairingPeer?
        var notice: String?
        var feedbackText: String?
        var feedbackIsWarning = true
        let stage: Stage
        let title: String
        var message: String?
        switch state {
        case .preparing:
            stage = .preparing
            title = appLocalized("Scan with Your iPhone")
            message = appLocalized("Preparing…")
        case .showingQRCode(let text, let expiresAt):
            stage = .qrCode(text: text, expiresAt: expiresAt)
            title = appLocalized("Scan with Your iPhone")
            message = appLocalized("In Ask Key on your iPhone, tap Pair a Mac, then scan this QR code.")
            notice = appLocalized("Scan only the QR code in this window. Never scan a QR code that someone sends you.")
        case .waitingForIPhone(let waitingPeer, _):
            stage = .waitingForIPhone
            peer = waitingPeer
            title = appLocalized("Waiting for the iPhone")
            message = appLocalized("The iPhone shows a pairing code once it has answered, and this window then asks for it.")
            notice = appLocalized("If the iPhone has shown a code for more than about 10 seconds while this window still waits, cancel and pair again.")
        case .enteringCode(let enteringPeer, _):
            stage = .codeEntry(accepted: false)
            peer = enteringPeer
            title = appLocalized("Enter the Pairing Code")
            message = Self.codeInstruction
            feedbackText = Self.entryFeedback(feedback)
        case .codeAccepted(let acceptedPeer):
            stage = .codeEntry(accepted: true)
            peer = acceptedPeer
            title = appLocalized("Enter the Pairing Code")
            message = Self.codeInstruction
            if isAuthenticating {
                feedbackText = appLocalized("Waiting for system authentication…")
                feedbackIsWarning = false
            } else if let failure = Self.authenticationFeedback(feedback) {
                feedbackText = failure
            } else {
                feedbackText = appLocalized("The code matches. Confirm to finish pairing; Ask Key asks for system authentication.")
                feedbackIsWarning = false
            }
        case .waitingForIPhoneConfirmation(let confirmingPeer):
            stage = .waitingForIPhoneConfirmation
            peer = confirmingPeer
            title = appLocalized("Confirm on the iPhone")
            message = appLocalized("Confirmed on this Mac. Tap Confirm Pairing on the iPhone to finish.")
        case .paired(let pairedPeer):
            stage = .paired
            title = appLocalized("Paired")
            message = appLocalizedFormat("This Mac and “%@” are paired. Ask Key sent a delivery check; until the device answers, it shows as “Not reached yet”.", pairedPeer.displayName)
        case .ended(let reason):
            stage = .ended(canPairAgain: reason != .identityUnusable && reason != .deviceLimitReached)
            title = appLocalized("Pairing Ended")
            message = Self.endMessage(reason)
        case .failed(let failure):
            stage = .failed
            title = appLocalized("Pairing Couldn't Start")
            message = Self.startFailureMessage(failure)
        }
        self.stage = stage
        self.title = title
        self.message = message
        self.peer = peer
        self.notice = notice
        self.feedback = feedbackText
        self.feedbackIsWarning = feedbackIsWarning
    }

    /// Every piece of text the sheet shows, for the check that none carries a code.
    var shownText: [String] {
        var texts = [title, message, notice, feedback].compactMap { $0 }
        if let peer { texts += [peer.displayName, Self.peerPlatform(peer)] }
        return texts
    }

    static var codeInstruction: String {
        appLocalized("Enter the code shown on the iPhone's Ask Key pairing screen. Never enter a code from a notification or a message. If that screen shows no code, cancel.")
    }

    /// "iPhone (not verified)": the platform is what the device says about itself.
    static func peerPlatform(_ peer: PairingPeer) -> String {
        appLocalizedFormat("%@ (not verified)", DevicesPresentation.platformName(peer.platform))
    }

    static func entryFeedback(_ feedback: PairingFeedback?) -> String? {
        switch feedback {
        case .invalidCodeFormat:
            return appLocalized("Enter the six half-width digits shown on the iPhone.")
        case .wrongCode(let remaining):
            return AppLanguage.localizedCount("That code doesn't match. %lld attempts left.",
                                              oneKey: "That code doesn't match. %lld attempt left.",
                                              count: remaining, language: AppLanguage.current)
        case .authenticationCancelled, .authenticationFailed, nil:
            return nil
        }
    }

    static func authenticationFeedback(_ feedback: PairingFeedback?) -> String? {
        switch feedback {
        case .authenticationCancelled:
            return appLocalized("System authentication was cancelled. Nothing was sent; you can confirm again.")
        case .authenticationFailed:
            return appLocalized("System authentication didn't succeed. Nothing was sent; you can confirm again.")
        case .invalidCodeFormat, .wrongCode, nil:
            return nil
        }
    }

    static func endMessage(_ reason: PairingEndReason) -> String {
        switch reason {
        case .cancelled:
            return appLocalized("Pairing was cancelled. Nothing was stored.")
        case .codeMismatch:
            return appLocalized("The code didn't match three times, so this pairing ended. Nothing was stored. Pair again to get a new QR code.")
        case .commitmentMismatch, .conflictingChallenge:
            return appLocalized("The iPhone's answer didn't match its request, so this pairing ended. Nothing was stored. Pair again, and scan only the QR code in this window.")
        case .cancelledByPeer, .noChallenge:
            return appLocalized("Pairing was cancelled on the iPhone. Nothing was stored.")
        case .undoneByPeer:
            return appLocalized("The iPhone cancelled this pairing after it finished, so the device was removed again.")
        case .secondRequest:
            return appLocalized("A second device answered this QR code, so this pairing ended. Nothing was stored. Pair again, and make sure nobody else can see the QR code.")
        case .expired:
            return appLocalized("The pairing session expired. Nothing was stored. Pair again to get a new QR code.")
        case .deviceLimitReached:
            return appLocalized("8 devices are already paired, the most Ask Key allows. Nothing was stored. Remove one, then pair again.")
        case .keyConflict:
            return appLocalized("This device's keys conflict with a device that is already paired. Nothing was stored.")
        case .peerRemoved:
            return appLocalized("The device was removed while pairing, so this pairing ended. Nothing was stored.")
        case .identityUnusable:
            return appLocalized("This Mac's device keys no longer work. Nothing was stored. Reset the device identity in Settings, then pair again.")
        }
    }

    static func startFailureMessage(_ failure: PairingStartFailure) -> String {
        switch failure {
        case .managementRequired:
            return appLocalized("Unlock credential management to pair a device.")
        case .secureEnclaveUnavailable:
            return appLocalized("This Mac has no Secure Enclave, so it can't keep device keys safe and can't pair.")
        case .accountUnavailable(let status):
            return DevicesPresentation.accountMessage(status)
                ?? appLocalized("Ask Key can't reach iCloud right now, so devices can't be reached. Check the connection.")
        case .iCloudUnavailable:
            return appLocalized("Ask Key couldn't prepare its iCloud inbox. Check the connection, then try again.")
        case .identityUnusable:
            return appLocalized("This Mac's device keys no longer work, for example after Migration Assistant or a restore. Reset the device identity, then pair your devices again.")
        case .storageUnavailable:
            return appLocalized("Ask Key couldn't read or save this Mac's device keys. Try again.")
        case .keyCreationFailed:
            return appLocalized("The Secure Enclave didn't create the keys. Try again.")
        }
    }
}
