import AppKit

/// The approval panel's window. Esc decides later with no control on the
/// card (#356): every key event AppKit delivers to the panel passes through
/// `sendEvent(_:)`, whichever view is first responder, so the panel takes
/// Esc there and hands it to `cancel`. Command-period and any other cancel
/// sent up the responder chain end in `cancelOperation(_:)` and do the same.
final class AgentApprovalPanel: NSPanel {
    var cancel: (@MainActor () -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if let cancel, Self.isEscape(event) { return cancel() }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        guard let cancel else { return super.cancelOperation(sender) }
        cancel()
    }

    /// Esc without Command, Control, Option or Shift, as the card's former
    /// `.cancelAction` shortcut matched it.
    static func isEscape(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 53 // kVK_Escape
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
}

@MainActor
enum AgentApprovalPanelFactory {
    static func make(contentSize: NSSize) -> AgentApprovalPanel {
        let panel = AgentApprovalPanel(
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
