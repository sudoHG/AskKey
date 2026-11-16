import Foundation
import UIKit
import UserNotifications

/// Connects the system's app and notification callbacks to `AppModel`. A
/// notification is only a hint to fetch the inbox; its text, category and
/// action are never acted on.
public final class AskKeyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor public private(set) lazy var model = AppModel(environment: .live())

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Set before launch finishes, so opening a notification reaches the app.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppLog.failure("Registering for remote notifications", error)
    }

    public func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                            fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let arrivedAt = Date()
        Task { @MainActor in
            await model.receivedPush(userInfo: userInfo, arrivedAt: arrivedAt, notificationIdentifier: nil)
            completionHandler(.newData)
        }
    }

    /// The thread the notification extension gives only a request it
    /// verified from a Mac this iPhone approves for (`NotificationProcessor`).
    static let verifiedRequestThreadPrefix = "mac_"

    /// How a notification shows while the app is in front (decision 8 of
    /// #344): a request the extension verified shows its banner, in
    /// Notification Center and with its sound, as when the app is not in
    /// front; any other push, such as the delivery check after pairing,
    /// stays silent as before. Only the presentation depends on it.
    static func foregroundPresentation(threadIdentifier: String) -> UNNotificationPresentationOptions {
        threadIdentifier.hasPrefix(verifiedRequestThreadPrefix) ? [.banner, .list, .sound] : []
    }

    /// A push for the app in front: a request's banner shows as usual and the
    /// app fetches at once. The request's page does not open by itself; the
    /// Requests tab's badge and its highlighted row show the new request.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let arrivedAt = notification.date
        let identifier = notification.request.identifier
        completionHandler(Self.foregroundPresentation(threadIdentifier: notification.request.content.threadIdentifier))
        Task { @MainActor in
            await model.receivedPush(userInfo: userInfo, arrivedAt: arrivedAt, notificationIdentifier: identifier)
        }
    }

    /// The person opened a notification: the app opens, fetches its inbox
    /// and opens the request it named if it verifies one; which action was
    /// chosen does not matter.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        let userInfo = notification.request.content.userInfo
        let arrivedAt = notification.date
        let identifier = notification.request.identifier
        completionHandler()
        Task { @MainActor in
            await model.receivedPush(userInfo: userInfo, arrivedAt: arrivedAt, notificationIdentifier: identifier,
                                     opened: true)
        }
    }
}
