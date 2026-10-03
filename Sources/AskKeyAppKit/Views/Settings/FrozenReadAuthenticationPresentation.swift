import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenReadAuthenticationPresentation: Equatable {
    let actionTitle: String
    let warning: String?
    let confirmationTitle: String?

    init(enabled: Bool, confirmingDisable: Bool) {
        actionTitle = enabled
            ? appLocalized("Turn Off…")
            : appLocalized("Turn On Again")
        warning = enabled && confirmingDisable
            ? appLocalized("After turning this off, one click releases Agent read requests without confirming it is you. Credential changes still require authentication.")
            : nil
        confirmationTitle = enabled && confirmingDisable
            ? appLocalized("Turn Off Anyway")
            : nil
    }

    init(actionTitle: String, warning: String?, confirmationTitle: String?) {
        self.actionTitle = actionTitle
        self.warning = warning
        self.confirmationTitle = confirmationTitle
    }
}
