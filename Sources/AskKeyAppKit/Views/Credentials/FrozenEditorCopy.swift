import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenEditorCopy {
    struct FieldCard: Equatable {
        let title: String
        let help: String
    }

    static var keyHeader: String { appLocalized("Key") }
    static var valueHeader: String { appLocalized("Value") }
    static var tableHeaders: [String] { [keyHeader, valueHeader] }
    static var customHelp: String { appLocalized("Enter keys and values like .env. Each value can be text or a file.") }
    static var addTextAction: String { appLocalized("Add Text Key") }
    static var addFileAction: String { appLocalized("Add File Key") }
    static var customAddActions: [String] { [addTextAction, addFileAction] }

    static func fieldCard(for component: CredentialComponentDraft) -> FieldCard {
        let title = CredentialTemplate.fieldTitle(for: component.name)
            + (component.isOptional ? appLocalized(" (Optional)") : "")
        let help: String
        switch component.name {
        case "API_KEY": help = appLocalized("The key or token from your provider")
        case "API_ENDPOINT": help = appLocalized("For example https://api.example.com; leave empty or remove if unused")
        default: help = ""
        }
        return .init(title: title, help: help)
    }

    static func kindLabel(for kind: CredentialPayloadKind) -> String {
        kind == .file ? appLocalized("File") : appLocalized("Text")
    }

    static func kindLabel(for component: CredentialComponentDraft) -> String {
        component.kind == .file
            ? appLocalized("File")
            : component.isSecret
                ? appLocalized("Protected")
                : appLocalized("Text")
    }
}
