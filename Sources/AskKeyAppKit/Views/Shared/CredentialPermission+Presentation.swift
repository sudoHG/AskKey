import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialPermission {
    static let prototypeCases: [CredentialPermission] = [.ask, .allowed, .hidden]

    var prototypeTitle: String {
        switch self {
        case .allowed: return appLocalized("Always Allow")
        case .ask: return appLocalized("Ask Every Time (Recommended)")
        case .hidden: return appLocalized("Do Not Allow Agent")
        }
    }
}
