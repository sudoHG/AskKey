import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialComponentDraft: Identifiable {
    enum EmptyValuePolicy {
        case reject
        case omitWhenNameIs(String)
    }

    let id = UUID()
    var name = ""
    var kind: CredentialPayloadKind = .text
    var isSecret = false
    var isRemovable = true
    var text = ""
    var file: FileImport.FrozenFile?
    var isOptional = false
    /// Added by the user in a template editor, so its key is typed rather than predefined.
    var isCustomKey = false
    var emptyValuePolicy = EmptyValuePolicy.reject
    var delivery: CredentialComponentDelivery?
    var masked = true
}
