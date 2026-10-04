import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialTemplate {
    /// Template chooser groups: the predefined templates, then the custom credential on its own.
    static let chooserGroups: [[CredentialTemplate]] = [
        [.api, .ssh, .githubApp, .apple, .cloud, .database],
        [.custom],
    ]

    var symbolName: String {
        switch self {
        case .api: return "key"
        case .ssh: return "terminal"
        case .githubApp: return "chevron.left.forwardslash.chevron.right"
        case .apple: return "signature"
        case .cloud: return "cloud"
        case .database: return "cylinder.split.1x2"
        case .custom: return "plus"
        }
    }

    /// The create page title for a new credential of this type.
    var editorTitle: String {
        switch self {
        case .api: return appLocalized("New API access credential")
        case .githubApp: return appLocalized("New GitHub App")
        case .apple: return appLocalized("New Apple signing credential")
        case .ssh: return appLocalized("New SSH identity")
        case .cloud: return appLocalized("New cloud account")
        case .database: return appLocalized("New database or service connection")
        case .custom: return appLocalized("New custom credential")
        }
    }
}
