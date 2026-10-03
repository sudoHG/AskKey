enum AgentApprovalPrivacyPolicy {
    static func plan(
        screenState: AgentApprovalScreenState,
        language: String = AppLanguage.current
    ) -> AgentApprovalPresentationPlan {
        switch screenState {
        case .locked, .unknown:
            return .lockedReminder(
                title: AppLanguage.localized("Ask Key has pending requests", language: language),
                body: AppLanguage.localized(
                    "Unlock your Mac to review a pending request.",
                    language: language
                )
            )
        case .unlocked:
            return .detailedConfirmation
        }
    }

    static func gatedRequest<Request>(
        screenState: AgentApprovalScreenState,
        load: () -> Request?
    ) -> AgentApprovalGatedRequest<Request> {
        switch plan(screenState: screenState) {
        case .lockedReminder(let title, let body):
            return .lockedReminder(title: title, body: body)
        case .detailedConfirmation:
            return .detailed(load())
        }
    }
}
