import AppKit
import SwiftUI
import AskKeyBroker

/// The approval prompt in the native alert layout: app icon, who wants which
/// credential, what will run, a collapsed Details section and stacked actions.
struct FrozenAgentApprovalPrompt: View {
    static let width: CGFloat = 300

    let request: BrokerApprovalOperationRequest
    var trustedCredentialName: String? = nil
    var expiresAt: Date? = nil
    let timedAllowanceEnabled: Bool
    var timedAllowanceMinutes: Int = 30
    var writeSummary: BrokerCredentialWriteSummary? = nil
    var organizationSummary: BrokerOrganizationSummary? = nil
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)? = nil
    /// The approval whose system authentication was cancelled. The prompt then
    /// offers to authenticate again for that same decision, or to deny.
    var cancelledAuthenticationDecision: BrokerApprovalDecision? = nil
    var detailsExpanded = false
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var showsDetails: Bool?

    private var content: ApprovalPromptContent {
        ApprovalPromptContent(
            request: request,
            credentialName: trustedCredentialName ?? request.credentialName ?? request.targetID
        )
    }

    private var contentWidth: CGFloat { Self.width - 2 * Theme.Spacing.lg }

    var body: some View {
        let _ = AppLanguage.store.resolved
        let content = content
        let commandFits = content.commandFits(prefix: appLocalized("to run"), width: contentWidth)
        let details = content.detailRows(commandFits: commandFits)
        let expanded = showsDetails ?? detailsExpanded
        VStack(spacing: 0) {
            appIcon
            Text(content.title)
                .font(Theme.Fonts.body.bold())
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(request.operation == .organize ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.md)
            if let command = content.commandSummary {
                (Text(appLocalized("to run")).font(Theme.Fonts.body)
                    + Text(verbatim: " ")
                    + Text(verbatim: command).font(Theme.Fonts.mono))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: content.fullCommand ?? command))
                    .padding(.top, Theme.Spacing.sm)
            }
            if cancelledAuthenticationDecision != nil {
                Text(content.cancelledAuthenticationNote)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.md)
                    .accessibilityIdentifier("approval-authentication-cancelled")
            }
            if !details.isEmpty {
                detailsToggle(expanded: expanded)
                    .padding(.top, Theme.Spacing.md)
                if expanded {
                    if request.operation == .organize {
                        ScrollView { detailRows(details) }.frame(maxHeight: 90)
                            .padding(.top, Theme.Spacing.md)
                    } else {
                        detailRows(details).padding(.top, Theme.Spacing.md)
                    }
                }
            }
            if request.operation == .organize {
                FrozenOrganizationApprovalContent(summary: organizationSummary)
                    .padding(.top, Theme.Spacing.lg)
            } else if request.operation != .read {
                FrozenWriteApprovalContent(writeSummary: writeSummary, revealMaterial: revealMaterial)
                    .padding(.top, Theme.Spacing.lg)
            }
            actions
                .padding(.top, Theme.Spacing.lg)
            footer
                .padding(.top, Theme.Spacing.md)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .environment(\.locale, AppLanguage.store.locale)
    }

    private var appIcon: some View {
        Image(nsImage: AppIcon.load())
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }

    private func detailsToggle(expanded: Bool) -> some View {
        Button {
            showsDetails = !expanded
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(appLocalized("Details")).font(Theme.Fonts.body)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .imageScale(.small)
            }
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("approval-details")
    }

    private func detailRows(_ rows: [ApprovalPromptContent.Row]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize()
                        Text(verbatim: row.value)
                            .font(row.monospaced ? Theme.Fonts.mono : Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(Theme.Fonts.body)
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let retry = cancelledAuthenticationDecision {
                ApprovalPromptButton(title: content.retryTitle, primary: true) { finish(retry) }
                    .disabled(request.operation == .organize && organizationSummary == nil)
                    .accessibilityIdentifier("approval-retry-authentication")
            } else {
                ApprovalPromptButton(title: primaryTitle, primary: true) { finish(.once) }
                    .disabled(request.operation == .organize && organizationSummary == nil)
                    .accessibilityIdentifier("approval-allow-once")
                if request.operation == .read, timedAllowanceEnabled {
                    ApprovalPromptButton(
                        title: appLocalizedFormat("Allow for %lld minutes", timedAllowanceMinutes),
                        primary: false
                    ) { finish(.timedAllow(duration: nil)) }
                        .help(appLocalized("Applies to all local callers for this credential · Revocable anytime"))
                        .accessibilityIdentifier("approval-allow-timed")
                }
            }
            ApprovalPromptButton(title: appLocalized("Deny"), primary: false) { finish(.deny) }
                .accessibilityIdentifier("approval-deny")
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.xs) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(appLocalizedFormat("Expires in %@", FrozenCountdown.format(deadline: expiresAt, now: context.date)))
                    .monospacedDigit()
            }
            Text(verbatim: "·")
            Button(appLocalized("Esc to decide later")) { finish(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.textTertiary)
    }

    private var primaryTitle: String {
        switch request.operation {
        case .read: return appLocalized("Allow Once")
        case .create: return appLocalized("Approve Creation")
        case .modify: return appLocalized("Approve Change")
        case .delete: return appLocalized("Approve Deletion")
        case .organize: return appLocalized("Approve Organization")
        }
    }
}

/// Full-width stacked alert button: the one filled accent action, or a white
/// bordered secondary action. "Deny" is secondary, never red.
private struct ApprovalPromptButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(primary ? Theme.onAccent : Theme.text)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.controlHeight)
                .background(primary ? Theme.accent : Theme.surface, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    if !primary {
                        RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.separator)
                    }
                }
                .shadow(color: Theme.cardShadow, radius: 1, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
