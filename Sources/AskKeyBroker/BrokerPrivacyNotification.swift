import Foundation

public struct BrokerPrivacyNotification: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let actions: [String]

    public static let approvalQueueBecameNonempty = BrokerPrivacyNotification(
        title: "Ask Key needs your attention",
        body: "Open Ask Key to review pending requests.",
        actions: []
    )
}
