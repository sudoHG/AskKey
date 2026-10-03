import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenImportConflictPresentation: Equatable {
    static let showsValues = true

    let warning: String?
    let choices: [String]
    let selectedChoice: FrozenImportConflictChoice
    let confirmTitle: String

    init(existingName: String?, choice: FrozenImportConflictChoice) {
        warning = existingName.map {
            appLocalizedFormat("A credential named “%@” already exists. Choose for the whole credential: skip it, or authenticate to replace it with the imported content.", $0)
        }
        choices = existingName == nil ? [] : [appLocalized("Skip"), appLocalized("Authenticate and Replace")]
        selectedChoice = choice
        confirmTitle = existingName != nil && choice == .skip
            ? appLocalized("Skip and Finish")
            : appLocalized("Confirm Import")
    }

    init(
        warning: String?,
        choices: [String],
        selectedChoice: FrozenImportConflictChoice,
        confirmTitle: String
    ) {
        self.warning = warning
        self.choices = choices
        self.selectedChoice = selectedChoice
        self.confirmTitle = confirmTitle
    }
}
