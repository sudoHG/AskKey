import CloudKit
import Foundation

/// The CloudKit names and subscription definitions of ADR 0013 → CloudKit
/// layout: one inbox zone per device in the private database, two record
/// types, and two query subscriptions per device on its own zone.
public enum CloudKitInboxLayout {
    public static let zonePrefix = "inbox_"
    public static let notificationCategory = "askkey.message"
    public static let alertTitleLocalizationKey = "push.message.title"
    public static let alertBodyLocalizationKey = "push.message.body"
    /// A push carries at most three desired keys (#281); each is a routing
    /// hint, checked against the signed message after decryption.
    public static let desiredKeys: [CKRecord.FieldKey] = [
        CloudKitMessageRecord.Field.kind.rawValue,
        CloudKitMessageRecord.Field.recipient.rawValue,
        CloudKitMessageRecord.Field.sender.rawValue,
    ]
    /// No field needs a queryable index in Production.
    public static let predicateFormat = "TRUEPREDICATE"

    /// `inbox_<device ID>`.
    public static func zoneName(for device: DeviceID) -> String {
        zonePrefix + device.text
    }

    /// The device's inbox zone in the signed-in account's private database.
    public static func zoneID(for device: DeviceID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName(for: device), ownerName: CKCurrentUserDefaultName)
    }

    /// `inbox_<device ID>_alert` for `AlertMessage`, `inbox_<device ID>_quiet`
    /// for `QuietMessage`.
    public static func subscriptionID(for device: DeviceID, recordType: MessageRecordType) -> CKSubscription.ID {
        switch recordType {
        case .alert: return zoneName(for: device) + "_alert"
        case .quiet: return zoneName(for: device) + "_quiet"
        }
    }

    /// The two subscriptions a device keeps on its own inbox zone: query
    /// subscriptions with `TRUEPREDICATE` and the single option
    /// `firesOnRecordCreation`, so deleting a processed message sends no push.
    /// An iPhone's `AlertMessage` subscription shows an alert by localization
    /// key with the default sound, mutable content and the category, so
    /// stage 4's notification extension needs no change; every other
    /// subscription is content-available only. All carry the same desired keys.
    public static func subscriptions(for device: DeviceID, platform: DevicePlatform) -> [CKQuerySubscription] {
        MessageRecordType.allCases.map { subscription(for: device, platform: platform, recordType: $0) }
    }

    public static func subscription(for device: DeviceID, platform: DevicePlatform,
                                    recordType: MessageRecordType) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: recordType.rawValue,
                                               predicate: NSPredicate(value: true),
                                               subscriptionID: subscriptionID(for: device, recordType: recordType),
                                               options: [.firesOnRecordCreation])
        subscription.zoneID = zoneID(for: device)
        subscription.notificationInfo = notificationInfo(platform: platform, recordType: recordType)
        return subscription
    }

    static func notificationInfo(platform: DevicePlatform, recordType: MessageRecordType) -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.desiredKeys = desiredKeys
        if platform == .iOS, recordType == .alert {
            info.titleLocalizationKey = alertTitleLocalizationKey
            info.alertLocalizationKey = alertBodyLocalizationKey
            info.soundName = "default"
            info.shouldSendMutableContent = true
            info.category = notificationCategory
        } else {
            info.shouldSendContentAvailable = true
        }
        return info
    }

    /// Whether a push is a hint for `device`'s own inbox. Subscriptions
    /// belong to the account, so every device of the account that runs the
    /// app receives every device's pushes; a device ignores those whose
    /// subscription ID or record zone is not its own.
    public static func isPush(subscriptionID: String?, zoneName: String?, for device: DeviceID) -> Bool {
        guard let subscriptionID, zoneName == self.zoneName(for: device) else { return false }
        return MessageRecordType.allCases.contains { self.subscriptionID(for: device, recordType: $0) == subscriptionID }
    }

    /// `isPush(subscriptionID:zoneName:for:)` for a received CloudKit
    /// notification; anything but a query notification is not a hint.
    public static func isPush(_ notification: CKNotification, for device: DeviceID) -> Bool {
        guard let query = notification as? CKQueryNotification else { return false }
        return isPush(subscriptionID: query.subscriptionID, zoneName: query.recordID?.zoneID.zoneName, for: device)
    }
}
