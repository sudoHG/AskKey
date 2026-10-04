import Foundation

enum WorkspaceVisualContract {
    static let windowWidth = 980.0
    static let windowHeight = 620.0
    static let sidebarWidth = 204.0
    // The accent role is the system accent color, so it has no fixed value.
    static let windowBackgroundHex = "F6F6F4"
    static let sidebarBackgroundHex = "ECEEEC"
    static let surfaceHex = "FFFFFF"
    static let textHex = "1C1F23"
    static let textSecondaryHex = "646B73"
    static let textTertiaryHex = "8E949A"
    static let warningHex = "C8342C"
    static let separatorOpacity = 0.09
    /// Title, headline, body, secondary and caption sizes, in that order.
    static let typeScale: [Double] = [22, 15, 13, 12, 11]
    static let monospaceSize = 12.0
    static let spacingScale: [Double] = [4, 8, 12, 16, 24, 32]
    /// Control, list group and alert corner radii, in that order.
    static let radii: [Double] = [6, 10, 13]

    struct WelcomeCopy: Equatable {
        let title: String
        let message: String
        let createAction: String
        let importAction: String
    }

    struct LockedCopy: Equatable {
        let title: String
        let message: String
        let action: String
        let pendingMessage: String?
        let pendingAction: String?

        init(
            title: String,
            message: String,
            action: String,
            pendingMessage: String? = nil,
            pendingAction: String? = nil
        ) {
            self.title = title
            self.message = message
            self.action = action
            self.pendingMessage = pendingMessage
            self.pendingAction = pendingAction
        }
    }

    static func welcomeCopy(language: String) -> WelcomeCopy {
        .init(
            title: AppLanguage.localized("Welcome to Ask Key", language: language),
            message: AppLanguage.localized(
                "Keep a complete set of credential materials together. When an Agent needs them, a system confirmation asks you to decide.",
                language: language
            ),
            createAction: AppLanguage.localized("Create Credential", language: language),
            importAction: AppLanguage.localized("Import from File", language: language)
        )
    }

    static func lockedCopy(
        language: String,
        credentialCount: Int,
        pendingRequestCount: Int = 0
    ) -> LockedCopy {
        let locale = AppLanguage.locale(for: language)
        return .init(
            title: AppLanguage.localized("Credential Management is Locked", language: language),
            message: AppLanguage.localizedCount(
                "%lld credentials are protected. Agent requests still appear for you to decide.",
                oneKey: "%lld credential is protected. Agent requests still appear for you to decide.",
                count: credentialCount,
                language: language
            ),
            action: AppLanguage.localized("Unlock Management", language: language),
            pendingMessage: pendingRequestCount > 0
                ? String(
                    format: AppLanguage.localized(
                        "%lld Agent requests are waiting. You can decide without unlocking management.",
                        language: language
                    ),
                    locale: locale,
                    arguments: [pendingRequestCount]
                )
                : nil,
            pendingAction: pendingRequestCount > 0
                ? AppLanguage.localized("Decide Requests Directly", language: language)
                : nil
        )
    }
}
