import AppKit

@MainActor
enum AgentApprovalPanelFactory {
    static func make(contentSize: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Approval is an independent user decision, not an auxiliary palette.
        // Keep it visible when the user returns to the requesting client.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.level = .modalPanel
        return panel
    }
}
