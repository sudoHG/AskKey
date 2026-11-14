import AskKeyDevices
import SwiftUI

/// The **Approve agent requests** sheet (ADR 0014 → Approvers): what will
/// leave the Mac, system authentication, the approver code until the iPhone
/// confirms it, then the result. The code is drawn only in the code box and
/// is hidden from accessibility; no identifier, label or value carries it.
struct ApproverConfirmationSheet: View {
    @Bindable var model: DevicesSettingsModel
    /// The last state, kept while the sheet animates away after it closed.
    @State private var shown: ApproverSheetPresentation?

    var body: some View {
        let _ = AppLanguage.store.resolved
        let sheet = model.approverSheet ?? shown
        Group {
            if let sheet {
                BackupSheetLayout(title: sheet.title, message: sheet.message) {
                    content(sheet)
                } actions: {
                    actions(sheet)
                }
                .controlSize(.large)
            }
        }
        .onAppear { shown = model.approverSheet }
        .onChange(of: model.approverSheet) { _, new in
            if let new { shown = new }
        }
    }

    @ViewBuilder
    private func content(_ sheet: ApproverSheetPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if case .code(let expiresAt) = sheet.stage {
                codeBox(expiresAt: expiresAt)
            }
            if let feedback = sheet.feedback {
                Text(feedback)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(sheet.feedbackIsWarning ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("devices-approver-feedback")
            }
            if sheet.stage != .enabled {
                deviceCard(sheet.device)
            }
            if sheet.showsWhatLeaves {
                BackupNotice(text: ApproverSheetPresentation.whatLeaves, isWarning: false)
                Text(ApproverSheetPresentation.nextSteps)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .code = sheet.stage {
                BackupNotice(text: ApproverSheetPresentation.codeNotice)
            }
        }
    }

    /// The code, its label and the time left. Only this view reads the code.
    private func codeBox(expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: Theme.Spacing.xs) {
                Text(appLocalized("Approver code"))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(verbatim: model.coordinator.approverCode?.formatted ?? "")
                    .font(Theme.Fonts.title.monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .textSelection(.disabled)
                    .accessibilityHidden(true)
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appLocalizedFormat("Expires in %@", FrozenCountdown.format(deadline: expiresAt, now: context.date)))
                        .font(Theme.Fonts.secondary.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("devices-approver-waiting")
            }
            .frame(maxWidth: .infinity)
            .padding(Theme.Spacing.md)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
        }
    }

    /// The selected iPhone: its name, the platform it declared, the paired
    /// date and the last delivery check.
    private func deviceCard(_ device: PairedDeviceRow) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: DevicesPresentation.platformSymbol(device.platform))
                .font(Theme.Icon.inlineStatus)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(Theme.Fonts.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(DevicesPresentation.approverDeviceSummary(device))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                Text((DevicesPresentation.rowDeliveryCheck(device) ?? DevicesPresentation.rowReachability(device)).text)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
    }

    @ViewBuilder
    private func actions(_ sheet: ApproverSheetPresentation) -> some View {
        Spacer(minLength: 0)
        switch sheet.stage {
        case .intro, .authenticating:
            cancelButton
            Button(appLocalized("Continue")) { Task { await model.continueApprover() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(sheet.stage == .authenticating)
                .accessibilityIdentifier("devices-approver-continue")
        case .code:
            cancelButton
        case .enabled:
            Button(appLocalized("Done")) { model.closeApproverSheet() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("devices-approver-done")
        case .ended(let canStartAgain):
            Button(appLocalized("Close")) { model.closeApproverSheet() }
                .keyboardShortcut(canStartAgain ? .cancelAction : .defaultAction)
                .accessibilityIdentifier("devices-approver-close")
            if canStartAgain {
                Button(appLocalized("Start Again")) { Task { await model.startApproverAgain() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("devices-approver-start-again")
            }
        }
    }

    private var cancelButton: some View {
        Button(appLocalized("Cancel")) { model.closeApproverSheet() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("devices-approver-cancel")
    }
}
