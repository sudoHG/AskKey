import AppKit

@MainActor
enum AgentApprovalPanelFactory {
    static func make(contentSize: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            // Non-activating: the panel takes keyboard focus without bringing
            // Ask Key, and any open management window, to the front.
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Approval is an independent user decision, not an auxiliary palette.
        // Keep it visible when the user returns to the requesting client.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .modalPanel
        return panel
    }
}
