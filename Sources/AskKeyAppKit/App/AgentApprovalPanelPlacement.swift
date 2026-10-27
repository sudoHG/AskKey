import AppKit
import SwiftUI

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
    static func targetVisibleFrame() -> NSRect? {
        let screens = NSScreen.screens
        let frame = screenFrame(
            pointer: NSEvent.mouseLocation, screens: screens.map(\.frame),
            keyWindowScreen: NSApp.keyWindow?.screen?.frame, mainScreen: NSScreen.main?.frame
        )
        return screens.first { $0.frame == frame }?.visibleFrame
    }

    @MainActor
    static func bringForward(_ panel: NSPanel) {
        if let visible = targetVisibleFrame() {
            panel.setFrameOrigin(centeredOrigin(size: panel.frame.size, visibleFrame: visible))
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct ApprovalMaximumHeightKey: EnvironmentKey {
    static let defaultValue = FrozenAgentApprovalPrompt.maximumHeight
}

extension EnvironmentValues {
    var approvalMaximumHeight: CGFloat {
        get { self[ApprovalMaximumHeightKey.self] }
        set { self[ApprovalMaximumHeightKey.self] = newValue }
    }
}

struct AgentApprovalPanelContent: View {
    var prompt: FrozenAgentApprovalPrompt
    @ObservedObject var layout: AgentApprovalPanelLayout

    var body: some View {
        prompt.environment(\.approvalMaximumHeight, layout.maximumHeight)
    }
}

/// Rebudgets the card after expansion, display moves and display reconfiguration.
@MainActor
final class AgentApprovalPanelLayout: ObservableObject {
    @Published private(set) var maximumHeight = FrozenAgentApprovalPrompt.maximumHeight
    private weak var panel: NSPanel?
    private let visibleFrame: @MainActor (NSPanel) -> NSRect?
    private var observers: [NSObjectProtocol] = []
    private var fitting = false

    init(panel: NSPanel, visibleFrame: @escaping @MainActor (NSPanel) -> NSRect?) {
        self.panel = panel
        self.visibleFrame = visibleFrame
    }

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    func refresh() {
        guard !fitting, let panel, let content = panel.contentView, let visible = visibleFrame(panel) else { return }
        fitting = true
        defer { fitting = false }
        let chrome = max(0, panel.frame.height - content.bounds.height)
            + content.safeAreaInsets.top + content.safeAreaInsets.bottom
        let height = min(FrozenAgentApprovalPrompt.maximumHeight, max(0, visible.height - chrome))
        if maximumHeight != height {
            maximumHeight = height
            // SwiftUI consumes the changed budget before the next fitting pass.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        panel.setContentSize(content.fittingSize)
        var frame = panel.frame
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
