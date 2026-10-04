import AskKeyVault

/// The credential saved during first run, kept only in memory so the welcome
/// page can name it without a management session.
struct OnboardingSavedCredential: Equatable {
    let name: String
    let permission: CredentialPermission
}

/// The welcome page's three-step list: store a credential, connect an Agent,
/// try once. Only the current step is emphasized and carries actions.
struct WelcomeStepsPresentation: Equatable {
    enum StepState: Equatable {
        case done
        case current
        case upcoming
    }

    struct Step: Equatable {
        let number: Int
        let title: String
        let message: String
        let state: StepState
    }

    let steps: [Step]

    /// Step 2 is current once a credential exists.
    var isConnectingAgent: Bool { steps[1].state == .current }

    init(storedCredentialCount: Int, savedCredential: OnboardingSavedCredential?) {
        let hasCredential = storedCredentialCount > 0
        let first: Step
        if hasCredential {
            first = Step(
                number: 1,
                title: savedCredential.map { appLocalizedFormat("Saved %@", $0.name) }
                    ?? appLocalized("First credential saved"),
                message: savedCredential.map { Self.permissionMessage($0.permission) }
                    ?? appLocalized("Review it in All credentials."),
                state: .done
            )
        } else {
            first = Step(
                number: 1,
                title: appLocalized("Store a credential"),
                message: appLocalized("An API key, login details, an SSH private key, or a .env file to import."),
                state: .current
            )
        }
        steps = [
            first,
            Step(
                number: 2,
                title: appLocalized("Connect your Agent"),
                message: appLocalized("Codex, Claude Code, Cursor or Grok CLI."),
                state: hasCredential ? .current : .upcoming
            ),
            Step(
                number: 3,
                title: appLocalized("Try it once"),
                message: appLocalized("Ask your Agent to run one command with this credential. Ask Key will ask you in a prompt."),
                state: .upcoming
            ),
        ]
    }

    private static func permissionMessage(_ permission: CredentialPermission) -> String {
        switch permission {
        case .allowed: return appLocalized("Permission: Allow. You can change it in All credentials.")
        case .ask: return appLocalized("Permission: Ask every time. You can change it in All credentials.")
        case .hidden: return appLocalized("Permission: Hidden. You can change it in All credentials.")
        }
    }
}
