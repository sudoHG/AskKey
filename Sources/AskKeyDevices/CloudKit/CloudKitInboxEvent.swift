import Foundation
import os

/// What the CloudKit transport logs. Each subscription save is logged with
/// its subscription ID and time and nothing else; no event carries message
/// content, record names or account identifiers.
public enum CloudKitInboxEvent: Hashable, Sendable {
    /// Saved because CloudKit answered that the subscription does not exist.
    case subscriptionSaved(subscriptionID: String, at: Date)
    /// Saved because the fetched subscription differed from ADR 0013, so
    /// someone had replaced it.
    case subscriptionRepaired(subscriptionID: String, at: Date)
    /// This device's own inbox zone was missing and was created again.
    case inboxZoneRecreated(at: Date)

    /// Writes the event to the unified log.
    public static let systemLog: @Sendable (CloudKitInboxEvent) -> Void = { event in
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AskKeyDevices", category: "CloudKitInbox")
        switch event {
        case .subscriptionSaved(let subscriptionID, let date):
            logger.notice("Saved subscription \(subscriptionID, privacy: .public) at \(date.ISO8601Format(), privacy: .public)")
        case .subscriptionRepaired(let subscriptionID, let date):
            logger.notice("Saved replaced subscription \(subscriptionID, privacy: .public) at \(date.ISO8601Format(), privacy: .public)")
        case .inboxZoneRecreated(let date):
            logger.notice("Created the missing inbox zone again at \(date.ISO8601Format(), privacy: .public)")
        }
    }
}
