import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenHotkeySettingsPresentation {
    static var optionIDs: [String] {
        GlobalHotkeyManager.Shortcut.allOptions.map(\.id)
    }

    static var includesOff: Bool {
        optionIDs.contains("disabled")
    }
}
