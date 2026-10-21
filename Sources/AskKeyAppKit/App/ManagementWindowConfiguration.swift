import SwiftUI

@MainActor
enum ManagementWindowConfiguration {
    // Both columns reserve this row inside the fixed, full-size content view.
    static let titlebarClearance: CGFloat = 32
    static let frameSize = NSSize(
        width: WorkspaceVisualContract.windowWidth,
        height: WorkspaceVisualContract.windowHeight
    )
    private static var isApplying = false

    static func makeWindow<Content: View>(rootView: Content) -> NSWindow {
        let hosting = NSHostingView(rootView: rootView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top))
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
        // The design specifies the outer frame, including the title bar.
        // Content-size limits can add that title bar again when AppKit applies them.
        window.minSize = frameSize
        window.maxSize = frameSize
        if window.frame.size != frameSize {
            var frame = window.frame
            frame.size = frameSize
            window.setFrame(frame, display: true)
        }
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
