import CloudKit
import Foundation

/// The parts of a subscription that ADR 0013 fixes and that CloudKit returns
/// unchanged, so a fetched subscription can be compared with the expected
/// one. Left out: the zone's owner name, which CloudKit may return resolved
/// to the user's record name instead of `CKCurrentUserDefaultName`; the
/// predicate object, compared by its format; and the order of the desired
/// keys, compared as a set.
struct CloudKitSubscriptionDefinition: Equatable {
    struct Notification: Equatable {
        var alertBody: String?
        var alertLocalizationKey: String?
        var alertLocalizationArgs: [String]?
        var title: String?
        var titleLocalizationKey: String?
        var titleLocalizationArgs: [String]?
        var subtitle: String?
        var subtitleLocalizationKey: String?
        var subtitleLocalizationArgs: [String]?
        var alertActionLocalizationKey: String?
        var alertLaunchImage: String?
        var soundName: String?
        var desiredKeys: Set<String>?
        var shouldBadge: Bool
        var shouldSendContentAvailable: Bool
        var shouldSendMutableContent: Bool
        var category: String?
        var collapseIDKey: String?

        init(_ info: CKSubscription.NotificationInfo) {
            alertBody = info.alertBody
            alertLocalizationKey = info.alertLocalizationKey
            alertLocalizationArgs = info.alertLocalizationArgs
            title = info.title
            titleLocalizationKey = info.titleLocalizationKey
            titleLocalizationArgs = info.titleLocalizationArgs
            subtitle = info.subtitle
            subtitleLocalizationKey = info.subtitleLocalizationKey
            subtitleLocalizationArgs = info.subtitleLocalizationArgs
            alertActionLocalizationKey = info.alertActionLocalizationKey
            alertLaunchImage = info.alertLaunchImage
            soundName = info.soundName
            desiredKeys = info.desiredKeys.map(Set.init)
            shouldBadge = info.shouldBadge
            shouldSendContentAvailable = info.shouldSendContentAvailable
            shouldSendMutableContent = info.shouldSendMutableContent
            category = info.category
            collapseIDKey = info.collapseIDKey
        }
    }

    var subscriptionID: String
    var isQuerySubscription: Bool
    var zoneName: String?
    var recordType: String?
    var predicateFormat: String?
    var options: UInt?
    var notification: Notification?

    init(_ subscription: CKSubscription) {
        subscriptionID = subscription.subscriptionID
        notification = subscription.notificationInfo.map(Notification.init)
        guard let query = subscription as? CKQuerySubscription, subscription.subscriptionType == .query else {
            isQuerySubscription = false
            return
        }
        isQuerySubscription = true
        zoneName = query.zoneID?.zoneName
        recordType = query.recordType
        predicateFormat = query.predicate.predicateFormat
        options = query.querySubscriptionOptions.rawValue
    }

    /// Whether `fetched` is the subscription `expected` defines.
    static func matches(_ fetched: CKSubscription, _ expected: CKSubscription) -> Bool {
        CloudKitSubscriptionDefinition(fetched) == CloudKitSubscriptionDefinition(expected)
    }
}
