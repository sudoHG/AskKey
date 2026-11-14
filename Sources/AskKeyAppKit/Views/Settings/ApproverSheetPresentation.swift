import AskKeyDevices
import Foundation

/// What the **Approve agent requests** sheet shows for one coordinator state
/// (ADR 0014 → Approvers): first what will leave the Mac, then system
/// authentication, then the approver code until the iPhone confirms it, then
/// the result. No state carries the code; only the sheet's code box reads
/// `DeviceCoordinator.approverCode`, so no title, message or accessibility
/// text here can contain it.
struct ApproverSheetPresentation: Equatable {
    enum Stage: Equatable {
        /// What will leave the Mac; **Continue** asks for system authentication.
        case intro
        case authenticating
        /// The code box, until `expiresAt`.
        case code(expiresAt: Date)
        case enabled
        case ended(canStartAgain: Bool)
    }

    let stage: Stage
    /// The iPhone the person selected, as the Mac lists it.
    let device: PairedDeviceRow
    let title: String
    let message: String?
    /// A wrong code from the iPhone, or the authentication prompt.
    let feedback: String?
    let feedbackIsWarning: Bool

    @MainActor
    init(device selected: PairedDeviceRow, state: ApproverConfirmationState?) {
        var device = selected
        var feedback: String?
        var feedbackIsWarning = true
        let stage: Stage
        let title: String
        let message: String?
        switch state {
        case nil:
            stage = .intro
            title = Self.introTitle(device)
            message = Self.introMessage
        case .authenticating(let row)?:
            device = row
            stage = .authenticating
            title = Self.introTitle(device)
            message = Self.introMessage
            feedback = appLocalized("Waiting for system authentication…")
            feedbackIsWarning = false
        case .waitingForIPhone(let row, let expiresAt, let remaining)?:
            device = row
            stage = .code(expiresAt: expiresAt)
            title = appLocalizedFormat("Type This Code on “%@”", row.displayName)
            message = appLocalized("In Ask Key on that iPhone, open this Mac in Paired Macs, choose Approve Requests from This Mac, type this code and confirm with Face ID or Touch ID.")
            if remaining < DeviceCoordinator.approverCodeAttempts {
                feedback = AppLanguage.localizedCount("The code typed on the iPhone doesn't match. %lld attempts left.",
                                                      oneKey: "The code typed on the iPhone doesn't match. %lld attempt left.",
                                                      count: remaining, language: AppLanguage.current)
            }
        case .enabled(let row)?:
            device = row
            stage = .enabled
            title = appLocalized("Approval Is On")
            message = appLocalizedFormat("“%@” now approves agent requests from this Mac. Allowing always needs Face ID or Touch ID on the iPhone. You can turn this off here at any time.", row.displayName)
        case .ended(let reason)?:
            stage = .ended(canStartAgain: Self.canStartAgain(after: reason))
            title = appLocalized("Approval Stays Off")
            message = Self.endMessage(reason)
        }
        self.stage = stage
        self.device = device
        self.title = title
        self.message = message
        self.feedback = feedback
        self.feedbackIsWarning = feedbackIsWarning
    }

    /// The intro and authentication steps list what will leave the Mac.
    var showsWhatLeaves: Bool { stage == .intro || stage == .authenticating }

    static func introTitle(_ device: PairedDeviceRow) -> String {
        appLocalizedFormat("Let “%@” Approve Agent Requests?", device.displayName)
    }

    static var introMessage: String {
        appLocalized("When this Mac is locked, or a request waits here for 20 seconds, Ask Key also sends it to this iPhone. Allowing on the iPhone needs Face ID or Touch ID.")
    }

    static var whatLeaves: String {
        appLocalized("Sent to this iPhone, encrypted: the agent's name, the credential's name, the command and folder, and the names the credential is delivered as. Never a credential value.")
    }

    static var nextSteps: String {
        appLocalized("Next, Ask Key asks for system authentication, then shows a code to type on this iPhone.")
    }

    static var codeNotice: String {
        appLocalized("This code appears only on this Mac. Never type it anywhere else or send it to anyone.")
    }

    static func canStartAgain(after reason: ApproverConfirmationEndReason) -> Bool {
        switch reason {
        case .authenticationCancelled, .authenticationFailed, .expired, .tooManyWrongCodes, .enteredOnOtherDevice, .notSaved:
            return true
        case .managementRequired, .unavailable, .deviceRemoved:
            return false
        }
    }

    static func endMessage(_ reason: ApproverConfirmationEndReason) -> String {
        switch reason {
        case .managementRequired:
            return appLocalized("Credential management is locked. Unlock it, then try again.")
        case .unavailable:
            return appLocalized("Approval can't be turned on now. Check that this Mac can reach iCloud and that the device is still paired.")
        case .authenticationCancelled:
            return appLocalized("System authentication was cancelled. Nothing changed.")
        case .authenticationFailed:
            return appLocalized("System authentication didn't succeed. Nothing changed.")
        case .expired:
            return appLocalized("The code expired before the iPhone confirmed it. Start again to get a new code.")
        case .tooManyWrongCodes:
            return appLocalized("The code typed on the iPhone didn't match three times, so this attempt ended. Start again to get a new code.")
        case .enteredOnOtherDevice(let name):
            return appLocalizedFormat("The code was typed on “%@”, not on the iPhone you chose, so this attempt ended. If you didn't type it there, remove that device. Otherwise start again and type the code on the iPhone you chose.", name)
        case .deviceRemoved:
            return appLocalized("The device was removed or paired again meanwhile, so approval stays off.")
        case .notSaved:
            return appLocalized("Ask Key couldn't save the setting. Start again.")
        }
    }
}
