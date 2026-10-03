import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenEditorMoreSettingsPresentation {
    static var agentInstructionsLabel: String { appLocalized("Instructions for Agent (Optional)") }
    static var privateNotesLabel: String { appLocalized("Private Notes (Optional)") }
    static var expiryLabel: String { appLocalized("Expiry Date (Optional)") }
    static var labels: [String] { [
        agentInstructionsLabel,
        privateNotesLabel,
        expiryLabel,
    ] }
    static var expiryHelp: String { appLocalized("The credential is disabled at expiry. Agent requests are denied, with reminders starting 7 days before.") }

    static func expiryDate(from text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return formatter.date(from: text)
    }

    static func expiryText(from date: Date) -> String {
        formatter.string(from: date)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
