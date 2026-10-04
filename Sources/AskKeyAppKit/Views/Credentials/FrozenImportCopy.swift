import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenImportCopy {
    static var defaultName: String { appLocalized("Imported Environment Variables") }
    static var nameHelp: String { appLocalized("Defaults to the file name; you can change it.") }
    static var contentsHeader: String { appLocalized("Contents · delivered as environment variables by key name") }

    static func previewSummary(itemCount: Int, skippedLineCount: Int) -> String {
        appLocalizedFormat(
            "Items read: %lld. Blank lines skipped: %lld. The original file is not modified.",
            itemCount,
            skippedLineCount
        )
    }

    /// Blank lines in the source; the empty remainder after a final newline is not a line.
    static func blankLineCount(in source: String) -> Int {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// The file name without its extension; a bare `.env` takes its folder's name.
    static func defaultName(forFileAt url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.isEmpty || stem.hasPrefix(".") else { return stem }
        let folder = url.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty || folder == "/" ? url.lastPathComponent : folder
    }
}
