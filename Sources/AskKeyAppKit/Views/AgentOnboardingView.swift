import AppKit
import SwiftUI

struct AgentOnboardingView: View {
    @Environment(VaultViewModel.self) private var vault
    @State private var showingRecoveryNotes = false
    @State private var copiedPromptClient: AgentClient?

    private var onboarding: AgentOnboardingCoordinator { vault.onboarding }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                PageHeader(
                    title: appLocalized("Agent access"),
                    subtitle: FrozenSettingsContract.agentAccessSubtitle
                )
                GroupedList {
                    ForEach(Array(AgentClient.allCases.enumerated()), id: \.element) { index, client in
                        if index > 0 {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                        }
                        clientRow(client)
                    }
                }
            }
            .padding(Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.windowBackground)
        .onAppear { vault.onboarding.appear() }
        .onDisappear { vault.onboarding.disappear() }
    }

    // MARK: - Row

    private func clientRow(_ client: AgentClient) -> some View {
        let session = onboarding.session(for: client)
        let presentation = AgentAccessPresentation(client: client, session: session)
        let expanded = onboarding.expandedClient == client
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                clientSymbol(client)
                Text(displayName(client))
                    .font(Theme.Fonts.body.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .frame(minWidth: Self.nameColumnWidth, alignment: .leading)
                StatusLabel(title: presentation.status.title, role: presentation.status.role)
                    .accessibilityIdentifier("onboarding-status-\(client.proofID)")
                Spacer(minLength: Theme.Spacing.md)
                Button(presentation.actionTitle(expanded: expanded)) {
                    toggleReview(client)
                }
                .buttonStyle(.secondaryAction)
                .disabled(session.attempt.phase.isInFlight && !expanded)
                .accessibilityIdentifier("onboarding-review-\(client.proofID)")
                .onboardingActivateWithKeyboard { toggleReview(client) }
                .registerAction(
                    "onboarding-review-\(client.proofID)",
                    action: { toggleReview(client) }
                )
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            if expanded {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 1)
                expandedSection(client, session: session, presentation: presentation)
                    .padding(.leading, Self.detailInset)
                    .padding(.trailing, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.windowBackground)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// A neutral SF Symbol per client; third-party logos are never used.
    private func clientSymbol(_ client: AgentClient) -> some View {
        Image(systemName: Self.symbolName(client))
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Self.symbolSize, height: Self.symbolSize)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
            .accessibilityHidden(true)
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedSection(
        _ client: AgentClient,
        session: AgentClientOnboardingSession,
        presentation: AgentAccessPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            stepProgress(presentation)
            headlineBlock(client, presentation: presentation)
            if let plan = session.plan, session.attempt.phase == .readyToConfirm {
                planDetails(plan)
            }
            if presentation.showsConnectedGuide {
                samplePrompt(client)
                Text(AgentOnboardingCopy.sshReminderNote.attributed(argumentFonts: [Theme.Fonts.mono]))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding-ssh-note-\(client.proofID)")
            }
            actionButtons(client, session: session, presentation: presentation)
        }
    }

    private func stepProgress(_ presentation: AgentAccessPresentation) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(AgentAccessStep.allCases) { step in
                if step != .check {
                    Text(verbatim: "—")
                        .foregroundStyle(Theme.textTertiary)
                }
                stepLabel(step, state: presentation.stepState(step), status: presentation.status)
            }
        }
        .font(Theme.Fonts.secondary)
        .accessibilityElement(children: .combine)
    }

    private func stepLabel(
        _ step: AgentAccessStep,
        state: AgentAccessStep.State,
        status: AgentAccessStatus
    ) -> some View {
        let color: Color = switch state {
        case .done: Theme.accent
        case .current: status == .needsAttention ? Theme.warning : Theme.accent
        case .upcoming: Theme.textTertiary
        }
        return HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: state == .done ? "checkmark" : "\(step.rawValue).circle")
                .accessibilityHidden(true)
            Text(step.title)
                .fontWeight(state == .upcoming ? .regular : .semibold)
        }
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func headlineBlock(_ client: AgentClient, presentation: AgentAccessPresentation) -> some View {
        if presentation.showsConnectedGuide {
            // One element so the completion reads as a single announcement.
            HStack(alignment: .top, spacing: 0) {
                headlineTexts(presentation)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onboarding-completion-\(client.proofID)")
        } else if presentation.headlineIsDiscoveryStatus {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(presentation.headline)
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("onboarding-discovery-\(client.proofID)")
                detailText(presentation.detail)
            }
        } else {
            headlineTexts(presentation)
        }
    }

    private func headlineTexts(_ presentation: AgentAccessPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(presentation.headline)
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            detailText(presentation.detail)
        }
    }

    @ViewBuilder
    private func detailText(_ detail: String) -> some View {
        if !detail.isEmpty {
            Text(detail)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func planDetails(_ plan: AgentOnboardingPlan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(plan.preconditionSummary)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if plan.codexHookPlan != nil {
                DisclosureGroup(appLocalized("Connection check configuration")) {
                    hookDescription(CodexOnboardingSetup.reviewedHookDescription)
                }
                .font(Theme.Fonts.secondary)
            }
            if plan.commandHookPlan != nil {
                DisclosureGroup(appLocalized("Connection check configuration")) {
                    hookDescription(CommandHookOnboardingSetup.reviewedHookDescription)
                }
                .font(Theme.Fonts.secondary)
            }
        }
    }

    private func hookDescription(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func samplePrompt(_ client: AgentClient) -> some View {
        let prompt = AgentOnboardingCopy.samplePrompt(credentialName: sampleCredentialName)
        let copied = copiedPromptClient == client
        return HStack(spacing: Theme.Spacing.md) {
            Text(prompt.attributed(argumentFonts: [Theme.Fonts.mono, Theme.Fonts.mono]))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding-sample-prompt-\(client.proofID)")
            Spacer(minLength: Theme.Spacing.md)
            Button(copied ? appLocalized("Copied") : appLocalized("Copy")) {
                copySamplePrompt(prompt.plainText, for: client)
            }
            .buttonStyle(.secondaryAction)
            .accessibilityIdentifier("onboarding-copy-prompt-\(client.proofID)")
        }
        .padding(.leading, Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.group)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    // MARK: - Actions

    @ViewBuilder
    private func actionButtons(
        _ client: AgentClient,
        session: AgentClientOnboardingSession,
        presentation: AgentAccessPresentation
    ) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if session.attempt.phase == .readyToConfirm {
                Button(appLocalized("Confirm connection")) {
                    Task { await onboarding.confirm(client) }
                }
                .buttonStyle(AgentAccessButtonStyle(prominent: true))
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
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("onboarding-not-now-\(client.proofID)")
                .onboardingActivateWithKeyboard { onboarding.collapse() }
                .registerAction(
                    "onboarding-not-now-\(client.proofID)",
                    action: { onboarding.collapse() }
                )
            } else if session.attempt.phase == .checking
                        || !session.attempt.phase.isWriteInFlight {
                checkOrCancelButton(client, session: session, presentation: presentation)
            }
            if session.attempt.phase.isInFlight {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(presentation.headline)
            }
            if presentation.offersRecoveryNotes {
                Button(appLocalized("Recovery notes")) { showingRecoveryNotes = true }
                    .buttonStyle(.secondaryAction)
                    .accessibilityIdentifier("onboarding-recovery-\(client.proofID)")
                    .popover(isPresented: $showingRecoveryNotes) {
                        Text(AgentOnboardingCopy.recoveryNotes(for: client))
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(Theme.Spacing.md)
                            .frame(width: Self.recoveryNotesWidth, alignment: .leading)
                    }
            }
            if presentation.offersIssueLink {
                Link(appLocalized("Report on GitHub Issues"), destination: AgentOnboardingCopy.issuesURL)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.accent)
                    .accessibilityIdentifier("onboarding-report-\(client.proofID)")
            }
        }
    }

    private func checkOrCancelButton(
        _ client: AgentClient,
        session: AgentClientOnboardingSession,
        presentation: AgentAccessPresentation
    ) -> some View {
        let checking = session.attempt.phase == .checking
        let checkedBefore = session.lastKnownResult != nil || session.attempt.failure != nil
        let title = checking
            ? appLocalized("Cancel check")
            : (checkedBefore ? appLocalized("Check again") : appLocalized("Check this Mac"))
        let identifier = checking
            ? "onboarding-cancel-\(client.proofID)"
            : "onboarding-check-\(client.proofID)"
        // The page's one primary action, except while cancelling, once the
        // client is connected, or when only recovery can help.
        let prominent = !checking
            && !presentation.showsConnectedGuide
            && session.attempt.phase != .recoveryRequired
        return Button(title) {
            if checking {
                onboarding.cancelCheck(client)
            } else {
                Task { await onboarding.startCheck(client) }
            }
        }
        .buttonStyle(AgentAccessButtonStyle(prominent: prominent))
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

    private func toggleReview(_ client: AgentClient) {
        if onboarding.expandedClient == client {
            onboarding.collapse()
        } else {
            copiedPromptClient = nil
            onboarding.explain(client)
        }
    }

    private func copySamplePrompt(_ text: String, for client: AgentClient) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedPromptClient = client
    }

    /// A credential Agents can see, so the sample prompt works as written.
    private var sampleCredentialName: String? {
        vault.credentials
            .filter { credential in
                credential.deletedAt == nil && credential.permission != .hidden
                    && credential.expiresAt.map { $0 > Date() } != false
            }
            .map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first
    }

    private func displayName(_ client: AgentClient) -> String {
        appLocalized(client.rawValue)
    }

    private static func symbolName(_ client: AgentClient) -> String {
        switch client {
        case .claudeCode: return "terminal"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .grok: return "greaterthan.square"
        }
    }

    private static let symbolSize: CGFloat = 28
    private static let nameColumnWidth: CGFloat = 120
    /// Lines the expanded section up with the client name.
    private static let detailInset = Theme.Spacing.lg + symbolSize + Theme.Spacing.md
    private static let recoveryNotesWidth: CGFloat = 320
}

/// The primary or secondary look for one button whose role changes with
/// the phase, so it keeps one identity across the swap.
private struct AgentAccessButtonStyle: ButtonStyle {
    let prominent: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            FrozenPrimaryButtonStyle().makeBody(configuration: configuration)
        } else {
            SecondaryButtonStyle().makeBody(configuration: configuration)
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
