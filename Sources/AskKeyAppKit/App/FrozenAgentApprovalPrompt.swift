import AppKit
import SwiftUI
import AskKeyBroker

/// The approval card in the native alert layout: app icon, one sentence
/// naming who wants to do what with which object, one short line under it,
/// a collapsed Details section and stacked actions. Expanded details scroll
/// inside the capped card so the actions stay visible.
struct FrozenAgentApprovalPrompt: View {
    static let width: CGFloat = 300
    /// Preferred cap; the production panel supplies a smaller screen budget.
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
    var authenticationOutcome: ManagementAuthenticationOutcome? = nil
    var detailsExpanded = false
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var showsDetails: Bool?
    @Environment(\.approvalMaximumHeight) private var availableHeight

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
        let expanded = showsDetails ?? detailsExpanded
        ApprovalCardLayout(maximumHeight: availableHeight - Theme.Spacing.lg) {
            ForEach(ApprovalCardPart.allCases, id: \.self) { part in
                cardPart(part, presentation: presentation, expanded: expanded)
                    .layoutValue(key: ApprovalCardPartKey.self, value: part)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .environment(\.locale, AppLanguage.store.locale)
    }

    @ViewBuilder
    func cardPart(_ part: ApprovalCardPart, presentation: Presentation, expanded: Bool) -> some View {
        switch part {
        case .icon:
            GeometryReader { geometry in
                if geometry.size.height >= 64 + Theme.Spacing.xl {
                    appIcon
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xl)
                }
            }
            .frame(idealHeight: 64 + Theme.Spacing.xl)
        case .header:
            header(presentation.content)
        case .content:
            ApprovalScrollArea(space: "approval-body", alignment: .center,
                identifier: expanded ? (isOrganize ? "approval-organization-operations" : "approval-details-rows") : "approval-header") {
                VStack(spacing: 0) {
                    if let warning = presentation.content.warning {
                        Text(verbatim: warning)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.warning)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Spacing.md)
                    }
                    if let message = authenticationMessageKey {
                        Text(appLocalized(message))
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Spacing.md)
                            .accessibilityIdentifier(authenticationOutcome == .failed
                                ? "approval-authentication-failed" : "approval-authentication-cancelled")
                    }
                    detailsToggle(expanded: expanded)
                        .padding(.top, Theme.Spacing.md)
                    if expanded {
                        details(presentation.details)
                            .padding(.top, Theme.Spacing.md)
                    }
                }
            }
        case .actions:
            actions(presentation.buttons)
                .padding(.top, Theme.Spacing.lg)
        case .footer:
            footer
                .padding(.top, Theme.Spacing.md)
        }
    }

    private var appIcon: some View {
        Image(nsImage: AppIcon.load())
            .resizable()
            .interpolation(.high)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }

    var authenticationMessageKey: String? {
        switch authenticationOutcome {
        case .failed: "Authentication failed. Nothing was handed over."
        case .cancelled: "Authentication cancelled. Nothing was handed over."
        default: cancelledAuthenticationDecision != nil
            ? "Authentication cancelled. Nothing was handed over." : nil
        }
    }

    /// Title and subtitle wrap freely; they scroll only when a name is too
    /// long for the card.
    private func header(_ content: ApprovalPromptContent) -> some View {
        ApprovalCardLayout(maximumHeight: .greatestFiniteMagnitude, minimumFlexibleHeight: 24) {
            title(content)
                .layoutValue(key: ApprovalCardFlexibleKey.self, value: 1)
            if content.commandSummary != nil || content.subtitle != nil {
                subtitle(content)
                    .layoutValue(key: ApprovalCardFlexibleKey.self, value: 2)
            }
        }
    }

    func title(_ content: ApprovalPromptContent) -> some View {
        ApprovalScrollArea(space: "approval-title-scroll", alignment: .center) {
            Text(verbatim: content.title)
                .font(Theme.Fonts.body.bold())
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Theme.Spacing.md)
                .accessibilityIdentifier("approval-title")
        }
    }

    func subtitle(_ content: ApprovalPromptContent) -> some View {
        ApprovalScrollArea(space: "approval-subtitle-scroll", alignment: .center) {
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

    /// Details share the scrolling body while the action row stays fixed.
    private func details(_ details: ApprovalDetailsContent) -> some View {
        ApprovalDetailsView(content: details, revealMaterial: revealMaterial)
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
