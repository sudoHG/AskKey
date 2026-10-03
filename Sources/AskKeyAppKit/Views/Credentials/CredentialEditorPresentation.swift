import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorPresentation {
    static func showsGlobalEnvironmentVariable(
        editingExisting: Bool,
        payloadKind: CredentialPayloadKind
    ) -> Bool {
        editingExisting && payloadKind != .bundle
    }
}
