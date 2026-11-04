import Foundation
import UserNotifications

/// Gentle reminder for an update that a scheduled check found (ADR 0011).
/// Sparkle still shows its alert without taking focus; this only adds one
/// notification, and only when the user already allows notifications. It
/// never requests permission, sets a badge or changes the activation policy.
package enum SoftwareUpdateReminder {
    /// One fixed identifier, so a newer reminder replaces an older one.
    package static let identifier = "com.sudohg.askkey.software-update"

    package static func shouldPost(userInitiated: Bool, authorization: UNAuthorizationStatus) -> Bool {
        guard !userInitiated else { return false }
        return authorization == .authorized || authorization == .provisional
    }

    package static func request(version: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = appLocalized("Ask Key update available")
        content.body = appLocalizedFormat("Version %@ is available. Click to review it.", version)
        content.userInfo = NotificationRoute.softwareUpdate.userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    /// Called just before Sparkle shows an update; a user-initiated check needs no reminder.
    package static func post(
        version: String,
        userInitiated: Bool,
        center: UNUserNotificationCenter = .current()
    ) {
        guard !userInitiated else { return }
        center.getNotificationSettings { settings in
            guard shouldPost(userInitiated: userInitiated, authorization: settings.authorizationStatus) else { return }
            center.add(request(version: version)) { error in
                if error != nil { NSLog("AskKey: update reminder notification failed") }
            }
        }
    }

    /// Called once the user has seen the update or the update session ends.
    package static func remove(center: UNUserNotificationCenter = .current()) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
