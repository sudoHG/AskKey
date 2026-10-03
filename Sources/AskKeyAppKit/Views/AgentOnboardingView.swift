import SwiftUI

struct AgentOnboardingView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var showingDiagnostics = false

    private var onboarding: AgentOnboardingCoordinator { vault.onboarding }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("Agent access"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(FrozenSettingsContract.agentAccessSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                }
                clientGroup(
                    title: appLocalized("Local clients"),
                    clients: [.codex, .cursor, .grok]
                )
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
        .onAppear { vault.onboarding.appear() }
        .onDisappear { vault.onboarding.disappear() }
    }

    private func clientGroup(title: String, clients: [AgentClient]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            ForEach(clients) { client in
                clientRow(client)
            }
        }
    }

    private func clientRow(_ client: AgentClient) -> some View {
        let session = onboarding.session(for: client)
        let expanded = onboarding.expandedClient == client
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(client))
                        .font(.system(size: 14, weight: .semibold))
                    Text(resultLine(session))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityLabel(resultAccessibility(session))
                    if let readiness = session.lastKnownResult?.discovery {
                        Text(AgentOnboardingCopy.discoveryStatus(readiness, for: client))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityIdentifier("onboarding-discovery-\(client.proofID)")
                    }
                }
                Spacer()
                Button(appLocalized("Review connection")) {
                    toggleReview(client, expanded: expanded)
                }
                .buttonStyle(.bordered)
                .disabled(session.attempt.phase.isInFlight && !expanded)
                .accessibilityIdentifier("onboarding-review-\(client.proofID)")
                .onboardingActivateWithKeyboard { toggleReview(client, expanded: expanded) }
                .registerAction(
                    "onboarding-review-\(client.proofID)",
                    action: { toggleReview(client, expanded: expanded) }
                )
            }
            if expanded {
                expandedSection(client, session: session)
            }
        }
        .padding(14)
        .background(Theme.panelBackground, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.sep, lineWidth: 1))
        .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func expandedSection(
        _ client: AgentClient,
        session: AgentClientOnboardingSession
    ) -> some View {
        if let completion = AgentOnboardingCopy.completion(for: client, session: session) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(completion.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(completion.detail)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.brandSubtle, in: .rect(cornerRadius: 6))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding-completion-\(client.proofID)")
        } else {
            Text(explanation(for: client, session: session))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let plan = session.plan, session.attempt.phase == .readyToConfirm {
            planSummary(plan)
        }
        if let failure = session.attempt.failure, session.attempt.phase != .explanation {
            failureBlock(client, session: session, failure: failure)
        }
        if session.attempt.phase.isInFlight {
            Text(progressText(session.attempt.phase))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .accessibilityLabel(progressText(session.attempt.phase))
        }
        actionButtons(client, session: session)
    }

    @ViewBuilder
    private func planSummary(_ plan: AgentOnboardingPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.scopeSummary)
                .font(.system(size: 11))
            Text(plan.preconditionSummary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            if plan.codexHookPlan != nil {
                DisclosureGroup(appLocalized("Connection check configuration")) {
                    Text(CodexOnboardingSetup.reviewedHookDescription)
                        .font(.system(size: 11))
                }
            }
            if plan.commandHookPlan != nil {
                DisclosureGroup(appLocalized("Connection check configuration")) {
                    Text(CommandHookOnboardingSetup.reviewedHookDescription)
                        .font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder
    private func failureBlock(
        _ client: AgentClient,
        session: AgentClientOnboardingSession,
        failure: AgentOnboardingFailure
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AgentOnboardingCopy.message(for: client, failure: failure, change: session.attempt.changeStatus))
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if session.attempt.phase == .recoveryRequired {
                Button(appLocalized("Recovery notes")) { showingDiagnostics = true }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showingDiagnostics) {
                        Text(AgentOnboardingCopy.recoveryNotes(for: client, change: session.attempt.changeStatus))
                            .font(.system(size: 11))
                            .padding(12)
                            .frame(width: 280, alignment: .leading)
                    }
            }
        }
    }

    @ViewBuilder
    private func actionButtons(
        _ client: AgentClient,
        session: AgentClientOnboardingSession
    ) -> some View {
        HStack(spacing: 8) {
            if session.attempt.phase == .readyToConfirm {
                Button(appLocalized("Confirm connection")) {
                    Task { await onboarding.confirm(client) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .disabled(session.attempt.changeStatus == .restoreFailed)
                .accessibilityIdentifier("onboarding-confirm-\(client.proofID)")
                .onboardingActivateWithKeyboard { Task { await onboarding.confirm(client) } }
                .registerAction(
                    "onboarding-confirm-\(client.proofID)",
                    action: { Task { await onboarding.confirm(client) } }
                )
                Button(appLocalized("Not now")) {
                    onboarding.collapse()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-not-now-\(client.proofID)")
                .onboardingActivateWithKeyboard { onboarding.collapse() }
                .registerAction(
                    "onboarding-not-now-\(client.proofID)",
                    action: { onboarding.collapse() }
                )
            } else if session.attempt.phase == .checking
                        || !session.attempt.phase.isWriteInFlight {
                checkOrCancelButton(client, session: session)
            }
        }
    }

    private func checkOrCancelButton(
        _ client: AgentClient,
        session: AgentClientOnboardingSession
    ) -> some View {
        let checking = session.attempt.phase == .checking
        let title = checking
            ? appLocalized("Cancel check")
            : (session.attempt.phase == .completed
               ? appLocalized("Check again")
               : appLocalized("Check this Mac"))
        let identifier = checking
            ? "onboarding-cancel-\(client.proofID)"
            : "onboarding-check-\(client.proofID)"
        return Button(title) {
            if checking {
                onboarding.cancelCheck(client)
            } else {
                Task { await onboarding.startCheck(client) }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.brand)
        .disabled(!checking && session.attempt.phase.isInFlight)
        .accessibilityIdentifier(identifier)
        .onboardingActivateWithKeyboard {
            if checking {
                onboarding.cancelCheck(client)
            } else {
                Task { await onboarding.startCheck(client) }
            }
        }
        .registerAction(identifier, action: {
            if checking {
                onboarding.cancelCheck(client)
            } else {
                Task { await onboarding.startCheck(client) }
            }
        })
        .id("onboarding-primary-\(client.proofID)")
    }

    private func toggleReview(_ client: AgentClient, expanded: Bool) {
        if expanded {
            onboarding.collapse()
        } else {
            onboarding.explain(client)
        }
    }

    private func displayName(_ client: AgentClient) -> String {
        appLocalized(client.rawValue)
    }

    private func explanation(for client: AgentClient, session: AgentClientOnboardingSession) -> String {
        return appLocalizedFormat(
            "Ask Key will first check this Mac and any existing %@ settings, then show the change that needs confirmation.",
            displayName(client)
        )
    }

    private func resultLine(_ session: AgentClientOnboardingSession) -> String {
        guard let result = session.lastKnownResult else {
            return appLocalized("Not checked yet")
        }
        let stamp = AgentOnboardingCopy.timestamp(result.checkedAt)
        switch result.outcome {
        case .verifiedConnected:
            return appLocalizedFormat("Last: verified connection · %@", stamp)
        case .configuredUnverified:
            if result.discovery != nil {
                return appLocalizedFormat("Last: MCP connected, setup incomplete · %@", stamp)
            }
            return appLocalizedFormat("Last: configured, unverified · %@", stamp)
        case .existingConfigUnverified:
            return appLocalizedFormat("Last: existing configuration, this check did not pass · %@", stamp)
        case .notConfigured:
            return appLocalizedFormat("Last: not configured · %@", stamp)
        }
    }

    private func resultAccessibility(_ session: AgentClientOnboardingSession) -> String {
        resultLine(session)
    }

    private func progressText(_ phase: AgentOnboardingPhase) -> String {
        switch phase {
        case .checking: return appLocalized("Checking…")
        case .authenticating: return appLocalized("Waiting for authentication…")
        case .applying: return appLocalized("Applying saved settings…")
        case .verifying: return appLocalized("Verifying…")
        default: return ""
        }
    }
}

private extension View {
    /// Tab still uses a SwiftUI focus node. Bare `.focusable()` does not
    /// activate a `Button`; Space/Return must call the same action here.
    func onboardingActivateWithKeyboard(_ action: @escaping () -> Void) -> some View {
        focusable()
            .onKeyPress(.space) {
                action()
                return .handled
            }
            .onKeyPress(.return) {
                action()
                return .handled
            }
    }
}

enum AgentOnboardingCopy {
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
              let result = session.lastKnownResult else { return nil }
        switch result.outcome {
        case .verifiedConnected:
            if client == .codex {
                guard result.discovery == .enabled else { return nil }
                return (
                    appLocalizedFormat("Complete: %@ is connected", appLocalized(client.rawValue)),
                    appLocalized("MCP is connected and credential discovery before SSH is enabled. Start a new Codex task to use it.")
                )
            }
            if client == .cursor || client == .grok {
                guard result.discovery == .configured || result.discovery == .enabled else { return nil }
                return (
                    appLocalizedFormat("Complete: %@ is connected", appLocalized(client.rawValue)),
                    appLocalizedFormat("MCP is connected and credential discovery is configured. Start a new %@ task to use it.", appLocalized(client.rawValue))
                )
            }
            return (
                appLocalizedFormat("Complete: %@ is connected", appLocalized(client.rawValue)),
                appLocalized("Connection verification passed. No further setup is needed.")
            )
        case .configuredUnverified, .existingConfigUnverified, .notConfigured:
            return nil
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale(for: AppLanguage.current)
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
            if client == .cursor || client == .grok {
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

    static func recoveryNotes(for client: AgentClient, change: AgentChangeStatus) -> String {
        return appLocalizedFormat(
            "A managed backup for %@ was kept. Stop ordinary retry. Review the backup notes, then continue only after the original settings are safe.",
            client.rawValue
        )
    }
}
