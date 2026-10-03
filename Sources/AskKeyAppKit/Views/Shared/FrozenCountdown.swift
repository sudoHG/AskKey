import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenCountdown {
    static func format(deadline: Date?, now: Date) -> String {
        guard let deadline else { return "--:--" }
        let remaining = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
