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

    /// A push for the app in front: fetch at once and show no banner.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let arrivedAt = notification.date
        let identifier = notification.request.identifier
        completionHandler([])
        Task { @MainActor in
            await model.receivedPush(userInfo: userInfo, arrivedAt: arrivedAt, notificationIdentifier: identifier)
        }
    }

    /// The person opened a notification: the app opens and fetches its
    /// inbox; which action was chosen does not matter.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let notification = response.notification
        let userInfo = notification.request.content.userInfo
        let arrivedAt = notification.date
        let identifier = notification.request.identifier
        completionHandler()
        Task { @MainActor in
            await model.receivedPush(userInfo: userInfo, arrivedAt: arrivedAt, notificationIdentifier: identifier)
        }
    }
}
