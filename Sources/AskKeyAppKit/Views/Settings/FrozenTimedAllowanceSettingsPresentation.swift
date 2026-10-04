import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenTimedAllowanceSettingsPresentation {
    static let choices = [15, 30, 60, 120]
    /// The picker tag for turning timed allow off.
    static let offTag = 0

    static func sanitized(_ minutes: Int) -> Int {
        if minutes > 0, minutes <= Int.max / 60 { return minutes }
        return 30
    }

    static func menuChoices(current: Int) -> [Int] {
        let value = sanitized(current)
        if choices.contains(value) { return choices }
        return (choices + [value]).sorted()
    }

    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 15: return appLocalized("15 minutes")
        case 30: return appLocalized("30 minutes")
        case 60: return appLocalized("60 minutes")
        case 120: return appLocalized("2 hours")
        default: return appLocalizedFormat("%lld minutes", minutes)
        }
    }

    static func help(minutes: Int) -> String {
        let value = sanitized(minutes)
        return appLocalizedFormat("A %lld-minute allowance applies to all local callers for that credential, then expires. Changing the default does not extend an allowance already granted.", value)
    }
}
