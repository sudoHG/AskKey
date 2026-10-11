import AppKit

enum AgentApprovalPanelPlacement {
    static func screenFrame(pointer: NSPoint, screens: [NSRect], keyWindowScreen: NSRect?, mainScreen: NSRect?) -> NSRect? {
        screens.first { $0.contains(pointer) } ?? keyWindowScreen ?? mainScreen
    }

    static func centeredOrigin(size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: min(max(visibleFrame.midY - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
    }

    @MainActor
    static func bringForward(_ panel: NSPanel) {
        let screens = NSScreen.screens
        let frame = screenFrame(
            pointer: NSEvent.mouseLocation, screens: screens.map(\.frame),
            keyWindowScreen: NSApp.keyWindow?.screen?.frame, mainScreen: NSScreen.main?.frame
        )
        let screen = screens.first { $0.frame == frame }
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(centeredOrigin(size: panel.frame.size, visibleFrame: visible))
        }
        panel.makeKeyAndOrderFront(nil)
    }
}
