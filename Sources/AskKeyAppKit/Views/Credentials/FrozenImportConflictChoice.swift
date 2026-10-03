import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenImportConflictChoice: CaseIterable, Equatable {
    case skip
    case replace
}
