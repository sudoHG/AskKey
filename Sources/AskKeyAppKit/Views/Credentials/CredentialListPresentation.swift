import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

/// One credential row: a neutral monogram from its type, the name, one
/// secondary line of facts and exactly one status label (its permission).
struct CredentialListPresentation: Equatable {
    let monogram: String
    let secondaryLine: String
    let statusTitle: String
    let statusRole: StatusLabel.Role

    init(credential: ManagedTextCredential, showsGroup: Bool = true) {
        let componentNames = credential.components.map(\.name)
        let template = CredentialTemplate.prototypeTemplate(componentNames: Set(componentNames))
        monogram = template.prototypeTitle.first.map { String($0).uppercased() } ?? "?"
        var facts = [
            template.prototypeTitle,
            appLocalizedFormat("%lld items", max(credential.components.count, 1)),
        ]
        let visibleNames = componentNames.filter { !$0.isEmpty }
        if !visibleNames.isEmpty {
            facts.append(visibleNames.joined(separator: appLocalized("Component list separator")))
        }
        if showsGroup, let group = credential.groupName {
            facts.append(group)
        }
        secondaryLine = facts.joined(separator: " · ")
        statusTitle = Self.statusTitle(credential.permission)
        statusRole = credential.permission == .allowed ? .accent : .neutral
    }

    static func statusTitle(_ permission: CredentialPermission) -> String {
        switch permission {
        case .allowed: return appLocalized("Allow")
        case .ask: return appLocalized("Ask every time")
        case .hidden: return appLocalized("Hidden")
        }
    }
}
