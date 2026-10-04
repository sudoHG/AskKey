import Foundation

/// The one status a client row shows on the Agent access page.
enum AgentAccessStatus: Equatable {
    case notChecked
    case notFound
    case notConnected
    case connected
    case needsAttention

    var title: String {
        switch self {
        case .notChecked: return appLocalized("Not checked")
        case .notFound: return appLocalized("Not found")
        case .notConnected: return appLocalized("Not connected")
        case .connected: return appLocalized("Connected")
        case .needsAttention: return appLocalized("Needs attention")
        }
    }

    var role: StatusLabel.Role {
        switch self {
        case .notChecked, .notFound, .notConnected: return .neutral
        case .connected: return .accent
        case .needsAttention: return .warning
        }
    }
}

/// The three steps of connecting a client.
enum AgentAccessStep: Int, CaseIterable, Identifiable {
    case check = 1
    case confirm
    case verify

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .check: return appLocalized("Check this Mac")
        case .confirm: return appLocalized("Confirm changes")
        case .verify: return appLocalized("Verify connection")
        }
    }

    enum State: Equatable {
        case done
        case current
        case upcoming
    }
}

/// What the Agent access page shows for one client, derived from its
/// onboarding session only.
struct AgentAccessPresentation: Equatable {
    let client: AgentClient
    let status: AgentAccessStatus
    /// The step in progress; nil once every step is done.
    let currentStep: AgentAccessStep?
    let headline: String
    let detail: String
    /// The headline is the credential discovery status of the last check.
    let headlineIsDiscoveryStatus: Bool
    /// Show the sample prompt and the SSH reminder note.
    let showsConnectedGuide: Bool
    /// Offer a link to GitHub Issues, because retrying cannot fix this.
    let offersIssueLink: Bool
    /// Offer the recovery notes for a change that could not be undone.
    let offersRecoveryNotes: Bool

    init(client: AgentClient, session: AgentClientOnboardingSession) {
        self.client = client
        let name = client.rawValue
        let attempt = session.attempt
        // A failure left from an earlier attempt is not shown while the
        // client is only being explained again.
        let failure = attempt.failure == .cancelled || attempt.phase == .explanation
            ? nil
            : attempt.failure
        let result = session.lastKnownResult
        let connected = result.map { AgentOnboardingCopy.isConnected(client, result: $0) } ?? false
        let discoveryGap = result?.discovery.flatMap {
            AgentOnboardingCopy.isDiscoveryReady($0, for: client) ? nil : $0
        }

        status = Self.status(attempt: attempt, failure: failure, result: result, connected: connected)
        currentStep = Self.currentStep(session: session, connected: connected)
        offersIssueLink = attempt.phase == .recoveryRequired || failure == .unsupportedVersion
        offersRecoveryNotes = attempt.phase == .recoveryRequired
        var headlineIsDiscoveryStatus = false
        var showsConnectedGuide = false

        switch attempt.phase {
        case .checking:
            headline = appLocalized("Checking this Mac…")
            detail = appLocalizedFormat("Ask Key is reading %@'s settings. Nothing is changed.", name)
        case .authenticating:
            headline = appLocalized("Waiting for authentication…")
            detail = appLocalizedFormat("Confirm it's you to let Ask Key change %@'s settings.", name)
        case .applying, .verifying:
            headline = appLocalizedFormat("Connecting %@…", name)
            detail = appLocalized("Ask Key is changing the settings, then verifying the connection.")
        case .recoveryRequired:
            headline = appLocalizedFormat("The original %@ settings could not be restored", name)
            detail = AgentOnboardingCopy.message(for: client, failure: .restoreFailed, change: attempt.changeStatus)
        case .readyToConfirm:
            headline = appLocalizedFormat("Confirm the changes to %@", name)
            detail = session.plan?.scopeSummary ?? ""
        default:
            if failure == .cliMissing {
                headline = appLocalizedFormat("%@ was not found on this Mac", name)
                detail = appLocalizedFormat(
                    "Install or open %@, then check again. Before changing anything, Ask Key shows you what will change.",
                    name
                )
            } else if let completion = AgentOnboardingCopy.completion(for: client, session: session) {
                headline = completion.title
                detail = completion.detail
                showsConnectedGuide = true
            } else if let discoveryGap, attempt.phase != .explanation {
                headline = AgentOnboardingCopy.discoveryStatus(discoveryGap, for: client)
                detail = failure.map {
                    AgentOnboardingCopy.message(for: client, failure: $0, change: attempt.changeStatus)
                } ?? AgentOnboardingCopy.message(for: client, failure: .discoverySetupFailed, change: .verifiedAndKept)
                headlineIsDiscoveryStatus = true
            } else if let failure {
                headline = appLocalizedFormat("%@ needs attention", name)
                detail = AgentOnboardingCopy.message(for: client, failure: failure, change: attempt.changeStatus)
            } else if attempt.phase == .needsAction || attempt.phase == .completed, let result {
                headline = appLocalizedFormat("%@ needs attention", name)
                detail = AgentOnboardingCopy.outcomeDetail(result.outcome, for: client)
            } else {
                headline = appLocalizedFormat("Check whether %@ is on this Mac", name)
                detail = appLocalizedFormat(
                    "Ask Key will first check this Mac and any existing %@ settings, then show the change that needs confirmation.",
                    name
                )
            }
        }
        self.headlineIsDiscoveryStatus = headlineIsDiscoveryStatus
        self.showsConnectedGuide = showsConnectedGuide
    }

    func stepState(_ step: AgentAccessStep) -> AgentAccessStep.State {
        guard let currentStep else { return .done }
        if step.rawValue < currentStep.rawValue { return .done }
        return step == currentStep ? .current : .upcoming
    }

    /// The row's one action. Its title says what pressing it does.
    func actionTitle(expanded: Bool) -> String {
        if expanded { return appLocalized("Collapse") }
        switch status {
        case .notChecked, .notFound, .notConnected: return appLocalized("Connect…")
        case .connected: return appLocalized("Show details")
        case .needsAttention: return appLocalized("Review")
        }
    }

    private static func status(
        attempt: AgentOnboardingAttempt,
        failure: AgentOnboardingFailure?,
        result: AgentLastKnownResult?,
        connected: Bool
    ) -> AgentAccessStatus {
        if attempt.phase == .recoveryRequired || attempt.phase == .rolledBack {
            return .needsAttention
        }
        if let failure {
            return failure == .cliMissing ? .notFound : .needsAttention
        }
        guard let result else { return .notChecked }
        if connected { return .connected }
        return result.outcome == .notConfigured ? .notConnected : .needsAttention
    }

    private static func currentStep(
        session: AgentClientOnboardingSession,
        connected: Bool
    ) -> AgentAccessStep? {
        let attempt = session.attempt
        switch attempt.phase {
        case .completed:
            return connected && attempt.failure == nil ? nil : .check
        case .readyToConfirm, .authenticating:
            return .confirm
        case .applying, .verifying, .rolledBack, .recoveryRequired:
            return .verify
        case .needsAction:
            if attempt.changeStatus != .notWritten { return .verify }
            return session.plan == nil ? .check : .confirm
        case .idle, .explanation, .checking:
            return .check
        }
    }
}

enum AgentOnboardingCopy {
    static let issuesURL = URL(string: "https://github.com/sudoHG/AskKey/issues")!

    /// The command in the sample prompt.
    static let sampleCommand = "./deploy.sh --env staging"

    /// Connected means the MCP connection is verified and credential
    /// discovery is ready.
    static func isConnected(_ client: AgentClient, result: AgentLastKnownResult) -> Bool {
        guard result.outcome == .verifiedConnected, let discovery = result.discovery else { return false }
        return isDiscoveryReady(discovery, for: client)
    }

    static func isDiscoveryReady(_ readiness: CredentialDiscoveryReadiness, for client: AgentClient) -> Bool {
        switch client {
        case .codex:
            return readiness == .enabled
        case .claudeCode, .cursor, .grok:
            return readiness == .configured || readiness == .enabled
        }
    }

    static func discoveryStatus(
        _ readiness: CredentialDiscoveryReadiness,
        for client: AgentClient
    ) -> String {
        if client == .codex {
            switch readiness {
            case .enabled: return appLocalized("Before SSH: credential discovery enabled")
            case .configured: return appLocalized("Before SSH: credential discovery configured")
            case .missing: return appLocalized("Before SSH: credential discovery not installed")
            case .disabled: return appLocalized("Before SSH: credential discovery disabled")
            case .untrusted: return appLocalized("Before SSH: credential discovery awaiting trust")
            case .unavailable: return appLocalized("Before SSH: credential discovery could not be verified")
            }
        }
        switch readiness {
        case .enabled: return appLocalized("Credential discovery is enabled")
        case .configured: return appLocalized("Credential discovery is configured")
        case .missing: return appLocalized("Credential discovery is not installed")
        case .disabled: return appLocalized("Credential discovery is disabled")
        case .untrusted: return appLocalized("Credential discovery is awaiting trust")
        case .unavailable: return appLocalized("Credential discovery could not be verified")
        }
    }

    static func completion(
        for client: AgentClient,
        session: AgentClientOnboardingSession
    ) -> (title: String, detail: String)? {
        guard session.attempt.phase == .completed,
              session.attempt.failure == nil,
              let result = session.lastKnownResult,
              isConnected(client, result: result) else { return nil }
        let name = appLocalized(client.rawValue)
        let detail = client == .claudeCode
            ? appLocalizedFormat("Start a new %@ session to use it. Try this:", name)
            : appLocalizedFormat("Start a new %@ task to use it. Try this:", name)
        return (appLocalizedFormat("%@ is connected", name), detail)
    }

    /// The sample prompt shown after a client connects. Arguments: the
    /// credential name, then the command; both are shown in monospace.
    static func samplePrompt(credentialName: String?) -> EmphasizedSentence {
        if let credentialName {
            return EmphasizedSentence(
                format: appLocalized("Use %1$@ from Ask Key to run %2$@"),
                arguments: [credentialName, sampleCommand]
            )
        }
        return EmphasizedSentence(
            format: appLocalized("Find the right credential in Ask Key and run %@"),
            arguments: [sampleCommand]
        )
    }

    /// The SSH reminder note; its argument is the `ssh` command.
    static var sshReminderNote: EmphasizedSentence {
        EmphasizedSentence(
            format: appLocalized("SSH reminder is on: before an Agent runs %@, it is reminded to check Ask Key. It is only a reminder and never authorizes anything."),
            arguments: ["ssh"]
        )
    }

    static func outcomeDetail(_ outcome: AgentKnownOutcome, for client: AgentClient) -> String {
        switch outcome {
        case .notConfigured:
            return appLocalizedFormat("%@ is not connected to Ask Key yet. Check again to set it up.", client.rawValue)
        case .configuredUnverified, .verifiedConnected:
            return appLocalizedFormat("Ask Key is set up in %@, but the connection is not verified. Check again.", client.rawValue)
        case .existingConfigUnverified:
            return appLocalized("Existing configuration is present, but this verification did not pass. Nothing was changed.")
        }
    }

    static func message(
        for client: AgentClient,
        failure: AgentOnboardingFailure,
        change: AgentChangeStatus
    ) -> String {
        let name = client.rawValue
        switch failure {
        case .discoverySetupCancelled:
            return appLocalized("Credential discovery setup was cancelled. The verified MCP connection was kept. Check again before continuing.")
        case .discoverySetupFailed:
            if client == .claudeCode || client == .cursor || client == .grok {
                return appLocalized("MCP is connected, but credential discovery is not verified. Check again to finish setup.")
            }
            return appLocalized("MCP is connected, but credential discovery before SSH is not verified. Check again to finish setup.")
        case .cancelled:
            return ""
        case .permissionDenied:
            return appLocalized("System authentication failed.")
        case .unsupportedVersion:
            return appLocalizedFormat("This version of %@ is not verified yet. Existing settings were left unchanged.", name)
        case .nameConflict:
            return appLocalized("Another connection already uses this name. Existing settings were kept.")
        case .unsafeConfig, .illegalConfig:
            return appLocalizedFormat("The existing %@ settings cannot be updated safely. Existing settings were left unchanged.", name)
        case .helperMismatch:
            return appLocalized("The Ask Key helper signature or version does not match. Reinstall Ask Key, then try again.")
        case .brokerUnavailable:
            return appLocalized("Ask Key is not running. Open Ask Key, then try again.")
        case .verificationFailed:
            if change == .restored {
                return appLocalized("The connection did not pass verification. Original settings were restored.")
            }
            if change == .notWritten {
                return appLocalized("Existing configuration is present, but this verification did not pass. Nothing was changed.")
            }
            return appLocalizedFormat("%@ did not complete the connection check. Restart %@, then try again.", name, name)
        case .restoreFailed:
            return appLocalized("The connection did not finish, and original settings could not be restored. Writing has stopped and the backup was kept.")
        case .cliMissing:
            return appLocalizedFormat("%@ was not found. Install or open it, then check again.", name)
        case .timedOut:
            return appLocalizedFormat("Could not read %@'s local configuration. Check again.", name)
        case .communicationFailed:
            return appLocalizedFormat("Could not read %@'s local configuration. Check again.", name)
        case .planChanged:
            return appLocalized("Local settings changed after review. Check again before confirming.")
        }
    }

    /// Self-contained notes for a change Ask Key could not undo: what
    /// happened, where the backup is and what to do next.
    static func recoveryNotes(for client: AgentClient) -> String {
        appLocalizedFormat(
            "Ask Key stopped changing %1$@'s settings because it could not put the original settings back. A copy of the original files was kept in Ask Key's data folder, under client-backups, and Ask Key will not retry this change on its own. Open %1$@ and check that it still works. If it does not, report it on GitHub Issues with the client name and this message. Never include credential values.",
            client.rawValue
        )
    }
}
