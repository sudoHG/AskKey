import AskKeyDevices
import Foundation

/// The extension's own strings, from its own catalog. The live table is the
/// extension bundle in the person's language; tests pass a fixed table.
struct NotificationStrings: Sendable {
    static let title = "push.message.title"
    static let genericBody = "push.message.body"
    static let requestBody = "push.request.body %@ %@ %@ %@"
    static let localAgent = "push.request.localAgent"

    private let lookup: @Sendable (String) -> String

    init(lookup: @escaping @Sendable (String) -> String) {
        self.lookup = lookup
    }

    /// The bundle that holds this code: the extension in the extension.
    static func bundle() -> NotificationStrings {
        let bundle = Bundle(for: NotificationBundleToken.self)
        return NotificationStrings { bundle.localizedString(forKey: $0, value: nil, table: nil) }
    }

    func text(_ key: String) -> String { lookup(key) }
}

private final class NotificationBundleToken {}

/// The card sentence of a detailed notification (ADR 0014 → Notification
/// Service Extension). Its four parts are the only content from a request
/// that can reach a notification: the requester's name, the iPhone's own
/// name for the Mac, the credential's name and the executable's last path
/// component. Never a value, an argument, the working directory, a purpose
/// or a variable name.
enum NotificationText {
    static let requesterLimit = 24
    static let macLimit = 24
    static let credentialLimit = 32
    static let executableLimit = 32

    /// “Codex” on “MacBook Pro” wants to use “GitHub Token” to run deploy.sh.
    static func requestBody(_ request: ApprovalRequest, macName: String, strings: NotificationStrings) -> String {
        let requester = part(request.requesterName, limit: requesterLimit)
        let parts = [
            requester.isEmpty ? strings.text(NotificationStrings.localAgent) : requester,
            part(macName, limit: macLimit),
            part(request.credentialName, limit: credentialLimit),
            part(lastPathComponent(request.executableName), limit: executableLimit),
        ]
        return String(format: strings.text(NotificationStrings.requestBody), arguments: parts.map { $0 as NSString })
    }

    /// Cleans a part with ADR 0013's display-name rule, replaces U+201C and
    /// U+201D with U+0022 so it cannot close the sentence's quotation marks,
    /// and shortens it in the middle to `limit` characters (extended
    /// grapheme clusters), keeping ⌈(limit − 1) / 2⌉ before the `…`.
    static func part(_ text: String, limit: Int) -> String {
        let cleaned = DeviceDisplayName.clean(text)
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        guard cleaned.count > limit else { return cleaned }
        let head = limit / 2
        return String(cleaned.prefix(head)) + "\u{2026}" + String(cleaned.suffix(limit - 1 - head))
    }

    /// The Mac sends the card's last path component already; anything up to
    /// a `/` is dropped again, so a notification never shows a folder.
    static func lastPathComponent(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }
}
