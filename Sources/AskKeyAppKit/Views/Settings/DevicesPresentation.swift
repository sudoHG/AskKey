import AskKeyDevices
import Foundation

/// The text Settings → Devices shows for the coordinator's state (ADR 0013 →
/// Mac App). Nothing here receives or derives the pairing code: the
/// coordinator never exposes it, so no label or accessibility text can carry it.
enum DevicesPresentation {
    /// A line under the section's pairing row: the default explanation, or why
    /// pairing or reaching devices is unavailable.
    struct Notice: Equatable {
        let text: String
        let isWarning: Bool
    }

    /// What the section says about pairing and reaching devices. One unavailable
    /// state at a time, the one the person has to act on first.
    static func sectionNotice(availability: DeviceServicesAvailability, account: DeviceAccountStatus,
                              deviceCount: Int, storageFailureMessage: String?) -> Notice {
        switch availability {
        case .secureEnclaveUnavailable:
            return warning("This Mac has no Secure Enclave, so it can't keep device keys safe and can't pair.")
        case .identityUnusable:
            return warning("This Mac's device keys no longer work, for example after Migration Assistant or a restore. Reset the device identity, then pair your devices again.")
        case .listRefused:
            return warning("The list of paired devices failed its integrity check, so Ask Key won't use it. Reset the device identity, then pair your devices again.")
        case .storageUnavailable:
            return Notice(text: storageFailureMessage
                ?? appLocalized("Devices are unavailable because Ask Key can't read this Mac's device keys right now."),
                isWarning: true)
        case .notConfigured, .loading, .ready:
            break
        }
        if let message = accountMessage(account) { return Notice(text: message, isWarning: true) }
        if deviceCount >= PairedDeviceList.maximumCount {
            return warning("8 devices are paired, the most Ask Key allows. Remove one to pair another.")
        }
        return Notice(text: appLocalized("Pair Ask Key on your iPhone with this Mac. They exchange encrypted messages through iCloud, so both must use the same Apple Account."), isWarning: false)
    }

    /// Why devices can't be reached, or nil when the account is available or
    /// not checked yet (a Mac without a device identity makes no iCloud request).
    static func accountMessage(_ account: DeviceAccountStatus) -> String? {
        switch account {
        case .unknown, .available:
            return nil
        case .noAccount:
            return appLocalized("iCloud is signed out, so paired devices can't be reached. To pair, sign in with the same Apple Account as your iPhone.")
        case .restricted:
            return appLocalized("iCloud is restricted on this Mac, for example by Screen Time or a device management profile, so devices can't be reached.")
        case .temporarilyUnavailable:
            return appLocalized("Ask Key can't reach iCloud right now, so devices can't be reached. Check the connection.")
        case .accountChanged:
            return appLocalized("This Mac now uses a different Apple Account than the one these devices were paired in, so they can't be reached. Sign back in, or remove them and pair again.")
        }
    }

    /// Whether **Pair a Device…** can start a session now. A refused state
    /// keeps its explanation on screen instead.
    static func canPair(availability: DeviceServicesAvailability, account: DeviceAccountStatus,
                        deviceCount: Int, isPairing: Bool) -> Bool {
        guard !isPairing, deviceCount < PairedDeviceList.maximumCount, account != .accountChanged else { return false }
        switch availability {
        case .ready, .loading, .storageUnavailable: return true
        case .notConfigured, .secureEnclaveUnavailable, .identityUnusable, .listRefused: return false
        }
    }

    /// Whether the section offers **Reset Device Identity…**.
    static func offersReset(_ availability: DeviceServicesAvailability) -> Bool {
        availability == .identityUnusable || availability == .listRefused
    }

    // MARK: Rows

    /// The platform the device declared about itself, never shown as verified.
    static func platformName(_ platform: DevicePlatform) -> String {
        switch platform {
        case .iOS: return "iPhone"
        case .macOS: return "Mac"
        }
    }

    static func platformSymbol(_ platform: DevicePlatform) -> String {
        switch platform {
        case .iOS: return "iphone"
        case .macOS: return "laptopcomputer"
        }
    }

    /// "iPhone · Paired <date>".
    static func rowSummary(_ row: PairedDeviceRow) -> String {
        appLocalizedFormat("%1$@ · Paired %2$@", platformName(row.platform), date(row.pairedAt, time: false))
    }

    /// "iPhone (not verified) · Paired <date>", for the approver sheet.
    static func approverDeviceSummary(_ row: PairedDeviceRow) -> String {
        appLocalizedFormat("%1$@ · Paired %2$@", appLocalizedFormat("%@ (not verified)", platformName(row.platform)),
                           date(row.pairedAt, time: false))
    }

    /// Whether the device was reached since pairing.
    static func rowReachability(_ row: PairedDeviceRow) -> Notice {
        switch row.reachability {
        case .notReachedYet:
            return Notice(text: appLocalized("Not reached yet"), isWarning: false)
        case .reached(let date):
            return Notice(text: appLocalizedFormat("Last reached %@", self.date(date, time: true)), isWarning: false)
        case .unreachable:
            return Notice(text: appLocalized("Can't be reached"), isWarning: true)
        }
    }

    /// The last delivery check, or nil before the first one and while the
    /// device can't be reached (why is said above the list; an older result
    /// would only contradict it).
    static func rowDeliveryCheck(_ row: PairedDeviceRow) -> Notice? {
        guard row.reachability != .unreachable else { return nil }
        switch row.lastDeliveryCheck {
        case .pending: return Notice(text: appLocalized("Delivery check sent"), isWarning: false)
        case .replied: return Notice(text: appLocalized("Delivery check answered"), isWarning: false)
        case .noReply: return Notice(text: appLocalized("Delivery check got no reply"), isWarning: true)
        case nil: return nil
        }
    }

    /// The line under **Approve agent requests** on an iPhone's row.
    static func approverCaption(_ row: PairedDeviceRow) -> String {
        row.isApprover
            ? appLocalized("Agent requests can also be decided on this iPhone.")
            : appLocalized("Agent requests are decided only on this Mac.")
    }

    static func issueMessage(_ issue: DeviceActionIssue) -> String {
        switch issue {
        case .managementRequired:
            return appLocalized("Credential management is locked. Unlock it, then try again.")
        case .deviceNotFound:
            return appLocalized("This device is no longer paired.")
        case .deliveryCheckFailed:
            return appLocalized("The delivery check couldn't be sent. Check the connection, then try again.")
        case .unpairNoticeNotSent:
            return appLocalized("The device was removed here, but Ask Key couldn't tell it. Remove this Mac on that device too.")
        case .actionFailed:
            return appLocalized("That didn't work. Try again.")
        }
    }

    static func removalWarning(_ name: String) -> String {
        appLocalizedFormat("This Mac stops trusting “%@” at once. Ask Key tries to tell the device so it can remove this Mac. If it still lists this Mac, remove this Mac on that device too.", name)
    }

    static func date(_ date: Date, time: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale(for: AppLanguage.current)
        formatter.dateStyle = .medium
        formatter.timeStyle = time ? .short : .none
        return formatter.string(from: date)
    }

    private static func warning(_ key: String) -> Notice {
        Notice(text: appLocalized(key), isWarning: true)
    }
}
