import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum RecycleBinPresentation {
    static func credentialMarker(name: String) -> String {
        name.first.map(String.init) ?? "凭" // i18n-literal: Preserve the existing empty-name credential marker until #83.
    }

    static func remainingDaysCopy(deletedAt: Date?, now: Date) -> String {
        guard let deletedAt else { return appLocalized("Days remaining unknown") }
        let purgeDate = deletedAt.addingTimeInterval(30 * 24 * 60 * 60)
        let days = max(0, Int(ceil(purgeDate.timeIntervalSince(now) / (24 * 60 * 60))))
        return appLocalizedFormat("%lld days remaining", days)
    }
}
