import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialTemplate {
    static func prototypeTemplate(componentNames: Set<String>) -> CredentialTemplate {
        for template in [githubApp, apple, ssh, cloud, database, api] {
            let drafts = template.components
            let allowedNames = Set(drafts.map(\.name))
            if let marker = drafts.first?.name,
               componentNames.contains(marker),
               componentNames.isSubset(of: allowedNames) {
                return template
            }
        }
        return custom
    }
}
