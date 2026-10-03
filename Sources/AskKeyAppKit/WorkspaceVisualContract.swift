import Foundation

enum WorkspaceVisualContract {
    static let windowWidth = 980.0
    static let windowHeight = 620.0
    static let sidebarWidth = 204.0
    static let accentHex = "0A6CFF"
    static let windowBackgroundHex = "F6F6F4"

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
