import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialListPresentation: Equatable {
    let tags: [String]

    init(credential: ManagedTextCredential) {
        let componentNames = Set(credential.components.map(\.name))
        let template = CredentialTemplate.prototypeTemplate(componentNames: componentNames)
        var tags = [
            template.prototypeTitle,
            appLocalizedFormat("%lld items", max(credential.components.count, 1)),
            credential.permission.prototypeTitle,
        ]
        tags.append(credential.groupName ?? appLocalized("Ungrouped"))
        self.tags = tags
    }
}
