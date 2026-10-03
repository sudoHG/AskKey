import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenImportCopy {
    static func previewSummary(itemCount: Int, skippedLineCount: Int) -> String {
        appLocalizedFormat("Contains %lld items; skipped %lld blank lines.", itemCount, skippedLineCount)
    }
}
