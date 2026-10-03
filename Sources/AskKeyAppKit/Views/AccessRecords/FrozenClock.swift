import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenClock {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale(for: AppLanguage.current)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
