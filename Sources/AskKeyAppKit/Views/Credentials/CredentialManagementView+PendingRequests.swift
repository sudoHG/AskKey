import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    var pendingRequestsDetail: some View {
        let storedApprovals = previewMode
            ? previewPendingRequests.map {
                BrokerPendingApproval(
                    requestID: $0.operationID,
                    capability: "preview",
                    request: $0,
                    expiresAt: Date().addingTimeInterval(300)
                )
            }
            : vault.pendingApprovals
        let approvals = storedApprovals
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("Pending Requests"))
                        .font(.system(size: 20, weight: .bold))
                    Text(appLocalized("Agent requests open a system confirmation. Missed or deferred requests remain here."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            .padding(28)
            if approvals.isEmpty, vault.pendingApprovalCount == 0 {
                WorkspaceEmptyState(
                    title: appLocalized("No Pending Requests"),
                    message: appLocalized("New requests open a confirmation and remain here if deferred."),
                    systemImage: "checkmark"
                )
            } else {
                if !approvals.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(approvals, id: \.request.operationID) { approval in
                                let request = approval.request
                                HStack(spacing: 12) {
                                    Image(systemName: request.operation == .read ? "command" : "pencil")
                                        .frame(width: 32, height: 32)
                                        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(request.callerName ?? appLocalized("Local Agent")) · \(requestOperationTitle(request.operation)) \(approval.displayCredentialName)")
                                            .font(.system(size: 13.5, weight: .semibold))
                                        TimelineView(.periodic(from: .now, by: 1)) { context in
                                            Text("\(request.callerPurpose ?? appLocalized("No purpose declared")) · \(appLocalized("Remaining")) \(FrozenCountdown.format(deadline: approval.expiresAt, now: context.date))")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Theme.textMuted)
                                        }
                                    }
                                    Spacer()
                                    pendingRequestAction(
                                        request,
                                        isDefault: request.operationID
                                            == approvals.first?.request.operationID
                                    )
                                }
                                .padding(14)
                                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                            }
                        }
                        .padding(.horizontal, 28)
                    }
                } else {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .frame(width: 32, height: 32)
                        .background(Theme.neutral(0.06), in: .rect(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appLocalizedFormat("%lld Agent requests are waiting", vault.pendingApprovalCount))
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(appLocalized("Credential contents stay masked until you open the confirmation."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Button(appLocalized("Open Confirmation")) {
                        NotificationCenter.default.post(name: .presentNextAgentApproval, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                }
                .padding(14)
                .background(Theme.panelBackground, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                .padding(.horizontal, 28)
                }
            }
            Spacer()
        }
        .background(Theme.windowBackground)
    }

    private func requestOperationTitle(_ operation: BrokerApprovalOperation) -> String {
        switch operation {
        case .read: return appLocalized("requests use of")
        case .create: return appLocalized("requests creation of")
        case .modify: return appLocalized("requests a change to")
        case .delete: return appLocalized("requests deletion of")
        }
    }

    @ViewBuilder
    private func pendingRequestAction(
        _ request: BrokerApprovalOperationRequest,
        isDefault: Bool
    ) -> some View {
        let button = Button(appLocalized("Open Confirmation")) {
            NotificationCenter.default.post(
                name: .presentNextAgentApproval,
                object: request.operationID
            )
        }
        .buttonStyle(FrozenPrimaryButtonStyle())
        .accessibilityIdentifier("request-\(request.operationID)")
        if isDefault {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

}
