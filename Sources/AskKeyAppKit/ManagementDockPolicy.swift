import AppKit

/// Management, its dialogs and the standalone windows Ask Key opens over it
/// (About, software updates) share one foreground session. A failed generic
/// approval or write-failure reminder can keep its Dock badge visible without taking focus.
struct ManagementDockPolicy {
    enum Event: Equatable {
        case launch(isActive: Bool)
        case applicationDidBecomeActive
        case applicationDidResignActive
        case managementWindowState(
            visible: Bool,
            miniaturized: Bool,
            key: Bool,
            applicationActive: Bool,
            ownedDialog: Bool = false
        )
        case managementWindowOpenedByUser
        case lockedApprovalReminderFallbackChanged(Bool)
        case agentWriteFailureStarted(UUID)
        case agentWriteFailureDeliveryFinished(UUID, LockedApprovalReminderDeliveryResult)
        case agentWriteFailureAcknowledged
    }

    private(set) var applicationActive = false
    private(set) var managementWindowVisible = false
    private(set) var managementWindowMiniaturized = false
    private(set) var managementWindowKey = false
    private(set) var managementOwnedDialog = false
    private(set) var lockedApprovalReminderFallbackVisible = false
    private(set) var agentWriteFailureReminder: UUID?
    private(set) var agentWriteFailureFallbackVisible = false
    private(set) var activationPolicy: NSApplication.ActivationPolicy = .accessory

    var isManagementWindowForeground: Bool {
        applicationActive
            && managementWindowVisible
            && !managementWindowMiniaturized
            && (managementWindowKey || managementOwnedDialog)
    }

    /// Returns a policy only when the event changes the requested policy.
    /// Keeping this transition edge-triggered prevents duplicate AppKit
    /// notifications from repeatedly calling setActivationPolicy.
    @discardableResult
    mutating func handle(_ event: Event) -> NSApplication.ActivationPolicy? {
        switch event {
        case .launch(let isActive):
            applicationActive = isActive
            managementWindowVisible = isActive
            managementWindowMiniaturized = false
            managementWindowKey = isActive
            managementOwnedDialog = false
        case .applicationDidBecomeActive:
            applicationActive = true
        case .applicationDidResignActive:
            applicationActive = false
        case .managementWindowState(
            let visible,
            let miniaturized,
            let key,
            let applicationActive,
            let ownedDialog
        ):
            self.applicationActive = applicationActive
            managementWindowVisible = visible
            managementWindowMiniaturized = miniaturized
            managementWindowKey = key
            managementOwnedDialog = ownedDialog
        case .managementWindowOpenedByUser:
            applicationActive = true
            managementWindowVisible = true
            managementWindowMiniaturized = false
            managementWindowKey = true
            agentWriteFailureReminder = nil
            agentWriteFailureFallbackVisible = false
        case .lockedApprovalReminderFallbackChanged(let visible):
            lockedApprovalReminderFallbackVisible = visible
        case .agentWriteFailureStarted(let attempt):
            agentWriteFailureReminder = attempt
        case .agentWriteFailureDeliveryFinished(let attempt, let result):
            guard agentWriteFailureReminder == attempt else { return nil }
            if !LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: result) {
                agentWriteFailureFallbackVisible = true
            }
        case .agentWriteFailureAcknowledged:
            agentWriteFailureReminder = nil
            agentWriteFailureFallbackVisible = false
        }

        let next: NSApplication.ActivationPolicy =
            isManagementWindowForeground || lockedApprovalReminderFallbackVisible || agentWriteFailureFallbackVisible
                ? .regular : .accessory
        guard next != activationPolicy else { return nil }
        activationPolicy = next
        return next
    }

    @MainActor
    static func hasManagementDialog(
        window: NSWindow,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?,
        modalWindow: NSWindow?
    ) -> Bool {
        if window.attachedSheet?.isVisible == true { return true }
        if let keyWindow, keyWindow !== window {
            if owns(keyWindow, from: window) { return true }
            if isStandaloneAppWindow(keyWindow) { return true }
        }
        // runModal file pickers and alerts have no parent. AppKit keeps the
        // management window (or its sheet) main while its app-modal panel is up.
        return modalWindow?.isVisible == true
            && mainWindow.map { owns($0, from: window) } == true
    }

    /// The About panel and Sparkle's update windows are ordinary titled windows
    /// without a parent. While management is in front they join its session,
    /// so becoming key does not hide the Dock icon and send them behind other
    /// apps. Approval panels are non-activating modal-level panels, the menu
    /// bar popover and the status item are untitled, and sheets of other
    /// windows have a parent; none of them joins. App-modal alerts run at the
    /// modal-panel level too, so they still count only through the main-window
    /// rule in `hasManagementDialog`.
    @MainActor
    static func isStandaloneAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
            && !window.styleMask.contains(.nonactivatingPanel)
            && window.level < .modalPanel
            && window.sheetParent == nil
            && window.parent == nil
    }

    @MainActor
    private static func owns(_ candidate: NSWindow, from window: NSWindow) -> Bool {
        if candidate === window { return true }
        if let parent = candidate.sheetParent ?? candidate.parent {
            return owns(parent, from: window)
        }
        return false
    }
}
