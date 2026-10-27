import AppKit
import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !ManagementAuthenticationSubprocess.isActive else { return }
        // Install before didFinishLaunching so cold-launch responses are delivered.
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.managementNavigation.handleNotificationResponse(
                actionIdentifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo,
                openManagement: self.openManagementWindow
            )
            completionHandler()
        }
    }
}
