import AppKit
import Foundation

@MainActor
struct ClipboardController {
    // org.nspasteboard.ConcealedType tells clipboard managers not to record the value.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copy(_ value: String, clearAfter delay: Double) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        let askKeyChangeCount = pasteboard.changeCount

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if pasteboard.changeCount == askKeyChangeCount,
               pasteboard.string(forType: .string) == value {
                pasteboard.clearContents()
            }
        }
    }
}
