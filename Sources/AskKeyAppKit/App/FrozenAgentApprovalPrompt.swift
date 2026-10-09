import AppKit
import SwiftUI
import AskKeyBroker

/// The approval card in the native alert layout: app icon, one sentence
/// naming who wants to do what with which object, one short line under it,
/// a collapsed Details section and stacked actions. Expanded details scroll
/// inside the capped card so the actions stay visible.
struct FrozenAgentApprovalPrompt: View {
    static let width: CGFloat = 300
    /// Keeps the whole card, footer included, above the Dock on the
    /// 768-point CI screen, where the panel's top sits under the menu bar.
    static let maximumHeight: CGFloat = 640
    static let contentWidth = width - 2 * Theme.Spacing.lg

    let request: BrokerApprovalOperationRequest
    var trustedCredentialName: String? = nil
    var expiresAt: Date? = nil
    let timedAllowanceEnabled: Bool
    var timedAllowanceMinutes: Int = 30
    var writeSummary: BrokerCredentialWriteSummary? = nil
    var organizationSummary: BrokerOrganizationSummary? = nil
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)? = nil
    /// The approval whose system authentication was cancelled. The card keeps
    /// the same buttons in the same order and says that nothing was handed over.
    var cancelledAuthenticationDecision: BrokerApprovalDecision? = nil
    var detailsExpanded = false
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var showsDetails: Bool?

    private var isRead: Bool { request.operation == .read }
    private var isOrganize: Bool { request.operation == .organize }

    /// What the card says and which buttons it offers, from the request and
    /// its frozen summary.
    struct Presentation {
        let write: FrozenWriteSummaryContent?
        let organization: FrozenOrganizationSummaryContent?
        let content: ApprovalPromptContent
        let details: ApprovalDetailsContent
        let buttons: [FrozenApprovalActions.Button]
    }

    var presentation: Presentation {
        let requester = ApprovalCopy.requester(request)
        let write = isRead || isOrganize ? nil : writeSummary.map { FrozenWriteSummaryContent(summary: $0, requester: requester) }
        let organization = isOrganize ? organizationSummary.map { FrozenOrganizationSummaryContent(summary: $0, requester: requester) } : nil
        let credentialName = trustedCredentialName ?? request.credentialName ?? request.targetID
        let content = ApprovalPromptContent(request: request, credentialName: credentialName,
            write: write, organization: organization)
        let details = ApprovalDetailsContent(request: request, credentialName: credentialName, write: write,
            organization: organization, timedAllowanceEnabled: timedAllowanceEnabled,
            timedAllowanceMinutes: timedAllowanceMinutes)
        let buttons = FrozenApprovalActions.buttons(operation: request.operation, timedAllowanceEnabled: timedAllowanceEnabled,
            minutes: timedAllowanceMinutes, valueOnlyChange: write?.valueOnlyChange ?? false,
            destructive: write?.isDestructive ?? organization?.isDestructive ?? false)
        return Presentation(write: write, organization: organization, content: content, details: details, buttons: buttons)
    }

    var body: some View {
        let _ = AppLanguage.store.resolved
        let presentation = presentation
        let content = presentation.content
        let expanded = showsDetails ?? detailsExpanded
        ApprovalCardLayout(maximumHeight: Self.maximumHeight - Theme.Spacing.xl - Theme.Spacing.lg) {
            appIcon
            header(content)
                .layoutValue(key: ApprovalCardFlexibleKey.self, value: 2)
            if cancelledAuthenticationDecision != nil {
                Text(appLocalized("Authentication cancelled. Nothing was handed over."))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.md)
                    .accessibilityIdentifier("approval-authentication-cancelled")
            }
            detailsToggle(expanded: expanded)
                .padding(.top, Theme.Spacing.md)
            if expanded {
                details(presentation.details)
                    .padding(.top, Theme.Spacing.md)
                    .layoutValue(key: ApprovalCardFlexibleKey.self, value: 1)
            }
            actions(presentation.buttons)
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

    /// Title and subtitle wrap freely; they scroll only when a name is too
    /// long for the card.
    private func header(_ content: ApprovalPromptContent) -> some View {
        ApprovalScrollArea(space: "approval-header", alignment: .center) {
            VStack(spacing: 0) {
                Text(verbatim: content.title)
                    .font(Theme.Fonts.body.bold())
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.md)
                    .accessibilityIdentifier("approval-title")
                if let command = content.commandSummary {
                    (Text(appLocalized("to run")).font(Theme.Fonts.body)
                        + Text(verbatim: " ")
                        + Text(verbatim: command).font(Theme.Fonts.mono))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: content.fullCommand ?? command))
                        .padding(.top, Theme.Spacing.sm)
                        .accessibilityIdentifier("approval-subtitle")
                } else if let subtitle = content.subtitle {
                    // A subtitle that names a group never cuts the name.
                    Text(verbatim: subtitle)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(request.operation == .create ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text(verbatim: subtitle))
                        .padding(.top, Theme.Spacing.sm)
                        .accessibilityIdentifier("approval-subtitle")
                }
            }
        }
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

    /// Scrolls inside the card's cap; edges fade while lines are hidden.
    private func details(_ details: ApprovalDetailsContent) -> some View {
        ApprovalScrollArea(space: "approval-details",
                           identifier: isOrganize ? "approval-organization-operations" : "approval-details-rows") {
            ApprovalDetailsView(content: details, revealMaterial: revealMaterial)
        }
    }

    private func actions(_ buttons: [FrozenApprovalActions.Button]) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(buttons, id: \.identifier) { button in
                ApprovalPromptButton(title: button.title, role: button.role) { finish(button.decision) }
                    .disabled(button.decision == .once && isOrganize && organizationSummary == nil)
                    .help(button.help ?? "")
                    .accessibilityIdentifier(button.identifier)
            }
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
}
