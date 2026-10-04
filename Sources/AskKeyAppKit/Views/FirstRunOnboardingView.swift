import AppKit
import SwiftUI

struct FirstRunOnboardingView: View {
    var onCreateCredential: () -> Void
    var onImportCredential: () -> Void
    /// Called after onboarding completes through "Connect an Agent".
    var onConnectAgent: () -> Void

    @Environment(VaultViewModel.self) private var vault
    @State private var launchAtLoginEnabled = true
    private let hasExplicitLoginChoice: Bool

    init(
        onCreateCredential: @escaping () -> Void,
        onImportCredential: @escaping () -> Void,
        onConnectAgent: @escaping () -> Void = {},
        initialLaunchAtLoginEnabled: Bool? = nil
    ) {
        self.hasExplicitLoginChoice = initialLaunchAtLoginEnabled != nil
        self.onCreateCredential = onCreateCredential
        self.onImportCredential = onImportCredential
        self.onConnectAgent = onConnectAgent
        _launchAtLoginEnabled = State(initialValue: initialLaunchAtLoginEnabled ?? true)
    }

    private var copy: WorkspaceVisualContract.WelcomeCopy {
        WorkspaceVisualContract.welcomeCopy(
            language: AppLanguage.resolve(mode: vault.languageMode)
        )
    }

    private var steps: WelcomeStepsPresentation {
        WelcomeStepsPresentation(
            storedCredentialCount: vault.onboardingCredentialCount,
            savedCredential: vault.onboardingSavedCredential
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                column
                    .frame(maxWidth: 500, alignment: .leading)
                    .padding(Theme.Spacing.xxl)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Theme.windowBackground)
        .environment(\.locale, vault.appLocale)
        .accessibilityIdentifier("first-run-onboarding")
        .onAppear {
            if !hasExplicitLoginChoice {
                launchAtLoginEnabled = vault.onboardingLaunchAtLoginEnabled
            }
        }
        .onChange(of: launchAtLoginEnabled) { _, value in
            vault.onboardingLaunchAtLoginEnabled = value
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            Text(vault.hasCompletedOnboarding ? appLocalized("No Credentials Yet") : copy.title)
                .font(Theme.Fonts.title)
                .foregroundStyle(Theme.text)
                .padding(.top, Theme.Spacing.xl)
            Text(vault.hasCompletedOnboarding ? appLocalized("Create or import a credential to keep the materials your Agent needs together.") : copy.message)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.sm)
            stepList
                .padding(.top, Theme.Spacing.xl)
            if !vault.hasCompletedOnboarding {
                launchAtLoginLine
                    .padding(.top, Theme.Spacing.lg)
            }
        }
    }

    private var stepList: some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.steps.enumerated()), id: \.element.number) { index, step in
                if index > 0 { Divider().overlay(Theme.separator) }
                stepRow(step)
            }
        }
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
    }

    private func stepRow(_ step: WelcomeStepsPresentation.Step) -> some View {
        let upcoming = step.state == .upcoming
        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            StepMarker(number: step.number, state: step.state)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(step.title)
                    .font(Theme.Fonts.headline)
                    .fontWeight(upcoming ? .regular : .semibold)
                    .foregroundStyle(upcoming ? Theme.textTertiary : Theme.text)
                Text(step.message)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(upcoming ? Theme.textTertiary : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if step.state == .current {
                    stepActions(step.number)
                        .padding(.top, Theme.Spacing.sm)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-step-\(step.number)")
    }

    @ViewBuilder
    private func stepActions(_ number: Int) -> some View {
        if number == 1 {
            HStack(spacing: Theme.Spacing.sm) {
                Button(copy.createAction, action: onCreateCredential)
                    .buttonStyle(FrozenPrimaryButtonStyle())
                    .accessibilityIdentifier("welcome-create-credential")
                BorderedActionButton(action: onImportCredential) {
                    Text(copy.importAction)
                }
                .accessibilityIdentifier("welcome-import-credential")
            }
        } else if number == 2 {
            HStack(spacing: Theme.Spacing.lg) {
                Button(appLocalized("Connect an Agent")) {
                    vault.completeOnboarding(enableLaunchAtLogin: launchAtLoginEnabled)
                    onConnectAgent()
                }
                .buttonStyle(FrozenPrimaryButtonStyle())
                .accessibilityIdentifier("welcome-connect-agent")
                Button(appLocalized("Later")) {
                    vault.completeOnboarding(enableLaunchAtLogin: launchAtLoginEnabled)
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.accent)
                .accessibilityIdentifier("welcome-later")
            }
        }
    }

    private var launchAtLoginLine: some View {
        let label = appLocalized("Launch at login. Agents get no credentials while Ask Key is off.")
        return HStack(spacing: Theme.Spacing.sm) {
            Toggle(label, isOn: $launchAtLoginEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .accessibilityIdentifier("welcome-launch-at-login")
            Text(label)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }
}

private struct StepMarker: View {
    let number: Int
    let state: WelcomeStepsPresentation.StepState

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(Theme.Fonts.secondary.weight(.bold))
                    .foregroundStyle(Theme.onAccent)
            case .current, .upcoming:
                let color = state == .current ? Theme.accent : Theme.textTertiary
                Circle().stroke(color, lineWidth: 1.5)
                Text(verbatim: "\(number)")
                    .font(Theme.Fonts.secondary.weight(.semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

struct FrozenLoginAtStartupPresentation: Equatable {
    let isEnabled: Bool
    let warning: String?

    init(isEnabled: Bool, showsWarning: Bool = true) {
        self.isEnabled = isEnabled
        warning = isEnabled || !showsWarning
            ? nil
            : appLocalized("After turning this off, Ask Key will not start when the Mac restarts, and Agents will not get any credentials.")
    }

    init(isEnabled: Bool, warning: String?) {
        self.isEnabled = isEnabled
        self.warning = warning
    }
}
