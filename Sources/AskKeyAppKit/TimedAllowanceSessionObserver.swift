import AppKit

/// Listens without changing pending approvals or the management session.
final class TimedAllowanceSessionObserver {
    private let screenNotifications: NotificationCenter
    private let workspaceNotifications: NotificationCenter
    private let screenLockObserver: NSObjectProtocol
    private let sleepObserver: NSObjectProtocol

    init(
        screenNotifications: NotificationCenter,
        workspaceNotifications: NotificationCenter,
        endAllowances: @escaping @Sendable () -> Void
    ) {
        self.screenNotifications = screenNotifications
        self.workspaceNotifications = workspaceNotifications
        screenLockObserver = screenNotifications.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil
        ) { _ in endAllowances() }
        sleepObserver = workspaceNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in endAllowances() }
    }

    deinit {
        screenNotifications.removeObserver(screenLockObserver)
        workspaceNotifications.removeObserver(sleepObserver)
    }
}
