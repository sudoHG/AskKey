import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var pendingRequestsDetail: some View {
        let approvals = previewMode
            ? previewPendingRequests.map {
                BrokerPendingApproval(
                    requestID: $0.operationID,
                    capability: "preview",
                    request: $0,
                    expiresAt: Date().addingTimeInterval(300)
                )
            }
            : vault.pendingApprovals
        return VStack(alignment: .leading, spacing: 0) {
            PageHeader(
                title: appLocalized("Pending requests"),
                subtitle: appLocalized("Missed or deferred requests stay here for 5 minutes.")
            )
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.lg)
            if approvals.isEmpty, vault.pendingApprovalCount == 0 {
                WorkspaceEmptyState(
                    title: appLocalized("No Pending Requests"),
                    message: appLocalized("New requests open a confirmation and remain here if deferred."),
                    systemImage: "tray"
                )
            } else if approvals.isEmpty {
                GroupedList {
                    pendingCountRow
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                Spacer()
            } else {
                ScrollView {
                    GroupedList {
                        ForEach(Array(approvals.enumerated()), id: \.element.request.operationID) { index, approval in
                            if index > 0 { GroupedListSeparator() }
                            pendingRequestRow(approval, isDefault: index == 0)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.xxl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.windowBackground)
    }

    private func pendingRequestRow(
        _ approval: BrokerPendingApproval,
        isDefault: Bool
    ) -> some View {
        let presentation = PendingRequestPresentation(approval: approval)
        return HStack(spacing: Theme.Spacing.md) {
            Image(nsImage: AppIcon.load())
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.sentence.attributed(argumentFonts: [
                    Theme.Fonts.body.weight(.semibold),
                    Theme.Fonts.body.weight(.semibold),
                    Theme.Fonts.mono,
                ]))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(PendingRequestPresentation.expiry(deadline: approval.expiresAt, now: context.date))
                        .font(Theme.Fonts.secondary)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            Button(appLocalized("Deny")) {
                if !previewMode { vault.denyPendingApproval(approval) }
            }
            .buttonStyle(.secondaryAction)
            .accessibilityIdentifier("request-deny-\(approval.request.operationID)")
            pendingRequestAction(approval.request, isDefault: isDefault)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.sentence.plainText)
    }

    private var pendingCountRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(nsImage: AppIcon.load())
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalizedFormat("%lld Agent requests are waiting", vault.pendingApprovalCount))
                    .font(Theme.Fonts.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(appLocalized("Credential contents stay masked until you open the confirmation."))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            Button(appLocalized("Open Confirmation")) {
                NotificationCenter.default.post(name: .presentNextAgentApproval, object: nil)
            }
            .buttonStyle(FrozenPrimaryButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// Opens the approval prompt for this request. Only the first row's
    /// action is the view's primary button.
    @ViewBuilder
    private func pendingRequestAction(
        _ request: BrokerApprovalOperationRequest,
        isDefault: Bool
    ) -> some View {
        let open = {
            NotificationCenter.default.post(
                name: .presentNextAgentApproval,
                object: request.operationID
            )
        }
        if isDefault {
            Button(appLocalized("Review and Decide"), action: open)
                .buttonStyle(FrozenPrimaryButtonStyle())
                .accessibilityIdentifier("request-\(request.operationID)")
                .keyboardShortcut(.defaultAction)
        } else {
            Button(appLocalized("Review and Decide"), action: open)
                .buttonStyle(.secondaryAction)
                .accessibilityIdentifier("request-\(request.operationID)")
        }
    }

}
