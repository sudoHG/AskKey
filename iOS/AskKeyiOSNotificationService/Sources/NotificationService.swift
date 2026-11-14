import AskKeyDevices
import Foundation
import UserNotifications

/// The notification's content. Every push first gets the generic text: the
/// extension's own title and body, no subtitle, no attachments, the app's
/// category and only the record name in the user info, so nothing an
/// attacker's subscription put in a push survives. Only a verified request
/// changes the body, the thread and the interruption level.
enum NotificationContentBuilder {
    /// The user info key the app reads the record name from (`PushHintReader`).
    static let recordNameKey = "askkey.recordName"

    static func content(_ decision: NotificationDecision, recordName: String?,
                        strings: NotificationStrings) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = strings.text(NotificationStrings.title)
        content.body = strings.text(NotificationStrings.genericBody)
        content.sound = .default
        content.categoryIdentifier = CloudKitInboxLayout.notificationCategory
        content.userInfo = recordName.map { [recordNameKey: $0] } ?? [:]
        content.interruptionLevel = .active
        if case .request(let request) = decision {
            content.body = request.body
            content.threadIdentifier = request.threadIdentifier
            content.interruptionLevel = request.isTimeSensitive ? .timeSensitive : .active
        }
        return content
    }
}

/// The Notification Service Extension. The content handler runs exactly
/// once: with the processor's content, or with the generic text when the
/// system's time runs out first, after which the processor sends nothing.
final class NotificationService: UNNotificationServiceExtension {
    /// Tests replace it before `didReceive`.
    var makeEnvironment: () -> NotificationEnvironment = NotificationEnvironment.live

    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?
    /// The running push, for tests to wait on.
    private(set) var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let push = PushInfo(userInfo: request.content.userInfo)
        let environment = makeEnvironment()
        let generic = NotificationContentBuilder.content(.generic(.notAMessagePush), recordName: push.recordName,
                                                         strings: environment.strings)
        lock.withLock {
            self.contentHandler = contentHandler
            fallback = generic
            work = Task { [weak self] in
                let decision = await NotificationProcessor(environment: environment).process(push)
                self?.deliver(NotificationContentBuilder.content(decision, recordName: push.recordName,
                                                                 strings: environment.strings))
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let (task, generic) = lock.withLock { (work, fallback) }
        task?.cancel()
        if let generic { deliver(generic) }
    }

    private func deliver(_ content: UNNotificationContent) {
        let handler: ((UNNotificationContent) -> Void)? = lock.withLock {
            defer { contentHandler = nil }
            return contentHandler
        }
        handler?(content)
    }
}

extension NotificationEnvironment {
    /// The extension's wiring: the shared keychain group and the CloudKit
    /// container from its Info.plist. Only the Ad Hoc export sets the
    /// container, and only that build carries the iCloud entitlement; every
    /// other build never creates a container and keeps the generic text.
    static func live() -> NotificationEnvironment {
        let bundle = Bundle.main
        let container = (bundle.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return NotificationEnvironment(
            keychain: ExtensionKeychain(store: DataProtectionKeychain(bundle: bundle)),
            restoreIdentity: { try SecureEnclaveDeviceIdentity.restore(from: $0) },
            makeInbox: { device in
                container.map {
                    CloudKitNotificationInbox(transport: CloudKitDeviceTransport(containerIdentifier: $0, deviceID: device,
                                                                                 platform: .iOS))
                }
            },
            clock: SystemDeviceClock(),
            strings: .bundle())
    }
}
