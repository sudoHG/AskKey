import AppKit
import SwiftUI
import AskKeyBroker

/// The approval card in the native alert layout: app icon, a title naming who
/// wants to do what to which object, fixed sections that scroll as one body
/// when the card would outgrow the screen, and stacked actions that state
/// each decision's consequence.
struct FrozenAgentApprovalPrompt: View {
    static let width: CGFloat = 300
    /// Keeps the whole card, footer included, above the Dock on the
    /// 768-point CI screen, where the panel's top sits under the menu bar.
    static let maximumHeight: CGFloat = 640
    static let contentWidth = width - 2 * Theme.Spacing.lg
    static let commandLineHeight = ceil(NSLayoutManager().defaultLineHeight(
        for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))

    let request: BrokerApprovalOperationRequest
    var trustedCredentialName: String? = nil
    var expiresAt: Date? = nil
    let timedAllowanceEnabled: Bool
    var timedAllowanceMinutes: Int = 30
    var writeSummary: BrokerCredentialWriteSummary? = nil
    var organizationSummary: BrokerOrganizationSummary? = nil
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)? = nil
    /// The approval whose system authentication was cancelled. The card then
    /// offers to authenticate again for that same decision, or to deny.
    var cancelledAuthenticationDecision: BrokerApprovalDecision? = nil
    var detailsExpanded = false
    let finish: (BrokerApprovalDecision?) -> Void
    @State private var showsDetails: Bool?

    private var isRead: Bool { request.operation == .read }
    private var isOrganize: Bool { request.operation == .organize }
    /// Write and organize cards are long, so their icon is smaller.
    private var compact: Bool { !isRead }

    var body: some View {
        let _ = AppLanguage.store.resolved
        let requester = ApprovalCopy.requester(request)
        let write = isRead || isOrganize ? nil : writeSummary.map { FrozenWriteSummaryContent(summary: $0, requester: requester) }
        let organization = isOrganize ? organizationSummary.map { FrozenOrganizationSummaryContent(summary: $0, requester: requester) } : nil
        let content = ApprovalPromptContent(request: request,
            credentialName: trustedCredentialName ?? request.credentialName ?? request.targetID,
            valueOnlyChange: write?.valueOnlyChange ?? false, organizationSteps: organization?.rows.count)
        let primary = FrozenApprovalActions.primary(operation: request.operation,
            valueOnlyChange: write?.valueOnlyChange ?? false, steps: organization?.rows.count,
            destructive: organization?.isDestructive ?? false)
        let topPadding = compact ? Theme.Spacing.lg : Theme.Spacing.xl
        ApprovalCardLayout(maximumHeight: Self.maximumHeight - topPadding - Theme.Spacing.lg) {
            icon
                .padding(.bottom, Theme.Spacing.md)
                .layoutValue(key: ApprovalCardCompactHeightKey.self, value: 40 + Theme.Spacing.md)
            title(content.title)
            cardBody(content, write: write, organization: organization)
                .layoutValue(key: ApprovalCardFlexibleKey.self, value: true)
            if cancelledAuthenticationDecision != nil {
                Text(content.cancelledAuthenticationNote)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.md)
                    .accessibilityIdentifier("approval-authentication-cancelled")
            }
            actions(primary, consequence: write?.consequence)
                .padding(.top, Theme.Spacing.lg)
            footer
                .padding(.top, Theme.Spacing.md)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, topPadding)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .environment(\.locale, AppLanguage.store.locale)
    }

    /// 64 points on a read card that fits; the layout shrinks it to 40 when
    /// the card would overflow. Write and organize cards always use 40.
    private var icon: some View {
        Image(nsImage: AppIcon.load())
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: compact ? 40 : 64, maxHeight: compact ? 40 : 64)
            .accessibilityHidden(true)
    }

    private func title(_ title: String) -> some View {
        Text(verbatim: title)
            .font(Theme.Fonts.body.bold())
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .help(Text(verbatim: title))
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.md)
            .accessibilityIdentifier("approval-title")
    }

    private func cardBody(_ content: ApprovalPromptContent, write: FrozenWriteSummaryContent?,
                          organization: FrozenOrganizationSummaryContent?) -> some View {
        ApprovalScrollArea(space: "approval-body", unit: isOrganize ? .steps : .sections,
                           identifier: isOrganize ? "approval-organization-operations" : "approval-body") { proxy in
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if isRead {
                    if let command = content.command { commandSection(command) }
                    if !content.receives.isEmpty {
                        ApprovalSection(title: content.receivesHeading, name: appLocalized("What the command receives"),
                                        identifier: "approval-delivers") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(content.receives.enumerated()), id: \.offset) { _, line in
                                    ApprovalLineText(line: line)
                                }
                            }
                        }
                    }
                }
                if let purpose = content.purpose {
                    ApprovalSection(title: appLocalized("Stated purpose (not verified)"), name: appLocalized("Stated purpose"),
                                    identifier: "approval-purpose") {
                        Text(verbatim: purpose).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let organization {
                    FrozenOrganizationApprovalContent(content: organization)
                } else if !isRead && !isOrganize {
                    FrozenWriteApprovalContent(operation: request.operation, content: write,
                        requester: content.requester, revealMaterial: revealMaterial)
                }
                details(content.detailRows, proxy: proxy)
            }
        }
    }

    private func commandSection(_ command: String) -> some View {
        ApprovalSection(title: appLocalized("Command to run"), identifier: "approval-command") {
            ApprovalScrollArea(space: "approval-command-lines", unit: .lines(height: Self.commandLineHeight),
                               maxHeight: Self.commandLineHeight * 4 + 1, indicatorOffset: Theme.Spacing.sm - 2) { _ in
                Text(verbatim: command)
                    .font(Theme.Fonts.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
        }
    }

    private func details(_ rows: [ApprovalPromptContent.Row], proxy: ScrollViewProxy) -> some View {
        let expanded = showsDetails ?? detailsExpanded
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                showsDetails = !expanded
                guard !expanded else { return }
                DispatchQueue.main.async {
                    withAnimation { proxy.scrollTo("approval-details-rows", anchor: .bottom) }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(appLocalized("Details")).font(Theme.Fonts.secondary)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .imageScale(.small)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("approval-details")
            if expanded {
                Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.label)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize()
                            Text(verbatim: row.value)
                                .font(row.monospaced ? Theme.Fonts.mono : Theme.Fonts.secondary)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(Theme.Fonts.secondary)
                .id("approval-details-rows")
                .accessibilityIdentifier("approval-details-rows")
            }
        }
        .approvalScrollMarker(name: appLocalized("Details"))
    }

    /// Each approving button states its consequence underneath, including
    /// the retry after a cancelled authentication.
    private func actions(_ primary: FrozenApprovalActions.Primary, consequence: String?) -> some View {
        let unavailable = isOrganize && organizationSummary == nil
        let timedScope = FrozenApprovalActions.timedScope(minutes: timedAllowanceMinutes)
        return VStack(spacing: Theme.Spacing.sm) {
            if let retry = cancelledAuthenticationDecision {
                let retriesTimed: Bool = { if case .timedAllow = retry { return true } else { return false } }()
                explained(retriesTimed ? timedScope : consequence) {
                    ApprovalPromptButton(title: FrozenApprovalActions.retry(retry, primary: primary, minutes: timedAllowanceMinutes),
                                         role: primary.role) { finish(retry) }
                        .disabled(unavailable)
                        .accessibilityIdentifier("approval-retry-authentication")
                }
            } else {
                explained(consequence) {
                    ApprovalPromptButton(title: primary.title, role: primary.role) { finish(.once) }
                        .disabled(unavailable)
                        .accessibilityIdentifier("approval-allow-once")
                }
                if isRead, timedAllowanceEnabled {
                    explained(timedScope) {
                        ApprovalPromptButton(title: FrozenApprovalActions.timed(minutes: timedAllowanceMinutes),
                                             role: .secondary) { finish(.timedAllow(duration: nil)) }
                            .accessibilityIdentifier("approval-allow-timed")
                    }
                }
            }
            ApprovalPromptButton(title: appLocalized("Deny"), role: .secondary) { finish(.deny) }
                .accessibilityIdentifier("approval-deny")
        }
    }

    private func explained(_ line: String?, @ViewBuilder button: () -> some View) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            button()
            if let line {
                Text(verbatim: line)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval-consequence")
            }
        }
    }

    private var footer: some View {
        Button { finish(nil) } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: appLocalizedFormat("Expires in %@ and nothing is handed over",
                    FrozenCountdown.format(deadline: expiresAt, now: context.date))
                    + " · " + appLocalized("Esc to hide; decide in Pending requests before it expires"))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.textTertiary)
        .help(appLocalized("When time runs out, the request is void and nothing is handed over or written; the agent is told it expired. Esc hides this card; the request stays in Pending requests until it expires."))
        .accessibilityIdentifier("approval-decide-later")
    }
}
