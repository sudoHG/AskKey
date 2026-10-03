import SwiftUI

@MainActor
enum ManagementWindowConfiguration {
    static let frameSize = NSSize(
        width: WorkspaceVisualContract.windowWidth,
        height: WorkspaceVisualContract.windowHeight
    )
    private static var isApplying = false

    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        let window = ManagementWindow(
            contentRect: NSRect(origin: .zero, size: frameSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.contentView = hosting
        apply(to: window)
        window.center()
        return window
    }

    static func apply(to window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.collectionBehavior.remove(.fullScreenPrimary)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        if let sizer = window.contentView as? HostingWindowSizing {
            sizer.stopResizingWindowFromContent()
        }
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        if abs(window.frame.width - frameSize.width) > 2
            || abs(window.frame.height - frameSize.height) > 2 {
            var frame = window.frame
            frame.size = frameSize
            window.setFrame(frame, display: true)
        }
        window.contentMinSize = frameSize
        window.contentMaxSize = frameSize
    }

    static func applyIfSettingsWindow(from note: Notification) {
        guard let window = note.object as? NSWindow,
              window.identifier?.rawValue == "settings" else { return }
        apply(to: window)
    }

    static func installObservers(
        center: NotificationCenter = .default
    ) -> [NSObjectProtocol] {
        [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    applyIfSettingsWindow(from: note)
                }
            }
        ]
    }
}
