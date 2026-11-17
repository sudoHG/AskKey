import Foundation
import UIKit
import UserNotifications

/// Connects the system's app and notification callbacks to `AppModel`. A
/// notification is only a hint to fetch the inbox; its text, category and
/// action are never acted on. The extension's mark on an answered delivery
/// check changes only how it shows while the app is in front.
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

    /// How a notification shows while the app is in front: the system
    /// banner, in Notification Center and with its sound, as when the app is
    /// not (decision 8 of #344). Whatever the extension could verify, the
    /// notification shows as it would in the background; the one exception
    /// is an answered delivery check (`foregroundPresentation(for:)`).
    static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .list, .sound]

    /// The user info key the notification extension sets only on a delivery
    /// check it verified and answered (`NotificationContentBuilder`, #361).
    /// A push's own payload never carries it: CloudKit puts only `aps` and
    /// `ck` at its top level.
    static let answeredDeliveryCheckKey = "askkey.answeredDeliveryCheck"

    /// `foregroundPresentation`, except for a delivery check the extension
    /// already answered: it needs nothing from the person, so it shows
    /// neither a banner nor in Notification Center and makes no sound (#361).
    /// Only this presentation reads the mark; the app still treats the
    /// notification as a hint to fetch its inbox.
    static func foregroundPresentation(for userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions {
        userInfo[answeredDeliveryCheckKey] as? Bool == true ? [] : foregroundPresentation
    }

    /// A push for the app in front: the banner shows as usual, except for a
    /// delivery check the extension answered, and the app fetches at once.
    /// The request's page does not open by itself; the Requests tab's badge
    /// and its highlighted row show the new request.
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let arrivedAt = notification.date
        let identifier = notification.request.identifier
        completionHandler(Self.foregroundPresentation(for: userInfo))
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
