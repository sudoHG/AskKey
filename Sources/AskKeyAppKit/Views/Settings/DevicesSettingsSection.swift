import AskKeyDevices
import SwiftUI

/// Settings → Devices (ADR 0013 → Mac App): **Pair a Device…**, the paired
/// devices with **Rename**, **Test Delivery** and **Remove**, and why pairing
/// or reaching them is unavailable. Builds without CloudKit show nothing.
struct DevicesSettingsSection: View {
    /// Held by `VaultViewModel` for the coordinator's life and passed in, as
    /// the Backup section receives the vault; this view owns no model.
    let model: DevicesSettingsModel?

    @MainActor
    init() {
        self.init(model: VaultViewModel.devicesSettingsModel)
    }

    init(model: DevicesSettingsModel?) {
        self.model = model
    }

    var body: some View {
        // A separate view keeps its body across the parent's redraw, so it
        // subscribes to the language itself.
        let _ = AppLanguage.store.resolved
        if let model, model.isSectionVisible {
            DevicesSectionContent(model: model)
        }
    }
}

private struct DevicesSectionContent: View {
    @Bindable var model: DevicesSettingsModel

    var body: some View {
        // Each separate view subscribes to the language itself; the parent's
        // redraw does not re-run a body whose inputs are unchanged.
        let _ = AppLanguage.store.resolved
        let notice = model.notice
        GroupedList(header: appLocalized("Devices")) {
            DevicesSettingRow(title: appLocalized("Pairing"), message: notice.text, isWarning: notice.isWarning) {
                if model.offersReset {
                    Button(appLocalized("Reset Device Identity…"), role: .destructive) { model.requestReset() }
                        .buttonStyle(.irreversibleAction)
                        .dimmedAndDisabled(model.confirmingReset)
                        .accessibilityIdentifier("settings-reset-device-identity")
                } else {
                    Button(appLocalized("Pair a Device…"), action: pairDevice)
                        .buttonStyle(.secondaryAction)
                        .dimmedAndDisabled(!model.canPair)
                        .accessibilityIdentifier("settings-pair-device")
                }
            }
            // The session decides whether the sheet shows. A live session ends
            // only through the sheet's buttons or the end of the management
            // session, so a dismissal reported by SwiftUI alone never cancels
            // a pairing; it only clears a session that has already finished.
            .sheet(isPresented: Binding(
                get: { model.isSheetPresented },
                set: { presented in
                    if !presented, model.coordinator.pairing?.isActive != true { Task { await model.closeSheet() } }
                }
            )) {
                DevicePairingSheet(model: model)
            }
            if model.confirmingReset {
                GroupedListSeparator()
                DevicesConfirmationRow(warning: appLocalized("Delete this Mac's device keys and its list of paired devices? Then remove this Mac on each paired device and pair again. This can't be undone.")) {
                    Button(appLocalized("Cancel")) { model.cancelReset() }
                        .buttonStyle(.secondaryAction)
                    Button(appLocalized("Reset"), role: .destructive) { Task { await model.confirmReset() } }
                        .buttonStyle(FrozenDangerButtonStyle())
                        .accessibilityIdentifier("settings-confirm-reset-device-identity")
                }
            }
            ForEach(model.coordinator.devices) { row in
                GroupedListSeparator()
                DeviceRow(model: model, row: row)
            }
            if model.coordinator.devices.isEmpty {
                GroupedListSeparator()
                emptyListRow
            }
            if let issue = model.coordinator.lastIssue {
                GroupedListSeparator()
                Text(DevicesPresentation.issueMessage(issue))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .accessibilityIdentifier("settings-devices-issue")
            }
        }
        .onAppear { Task { await model.sectionOpened() } }
    }

    /// Stands in for the list while no device is listed.
    ///
    /// It is also the fix for #299: on macOS 26, Pair a Device… received no
    /// clicks while this box held only the Pairing row, so it did nothing
    /// until a device was listed. A second row as tall as the Pairing row
    /// restored the click in CI
    /// (https://github.com/sudoHG/AskKey/issues/299,
    /// https://github.com/sudoHG/AskKey/actions/runs/43048425691). Reset
    /// Device Identity… shares the box and was not tested there. Check
    /// Pair a Device… on macOS 26 before removing this row or making it shorter.
    private var emptyListRow: some View {
        Text(appLocalized("Paired devices appear here."))
            .font(Theme.Fonts.secondary)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityIdentifier("settings-devices-empty")
    }

    private func pairDevice() {
        Task { await model.pairDevice() }
    }
}

/// One paired device: name, platform, paired date, last reached and the
/// last delivery check, with its actions or an open rename or removal.
private struct DeviceRow: View {
    @Bindable var model: DevicesSettingsModel
    let row: PairedDeviceRow
    @FocusState private var nameFocused: Bool

    var body: some View {
        let _ = AppLanguage.store.resolved
        let isRenaming = model.renaming == row.id
        let reachability = DevicesPresentation.rowReachability(row)
        let check = DevicesPresentation.rowDeliveryCheck(row)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.md) {
                Image(systemName: DevicesPresentation.platformSymbol(row.platform))
                    .font(Theme.Icon.inlineStatus)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if isRenaming {
                        TextField(appLocalized("Name"), text: $model.renameDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Fonts.body)
                            .frame(maxWidth: 240)
                            .focused($nameFocused)
                            .onSubmit { Task { await model.saveRename() } }
                            .onAppear { nameFocused = true }
                            .accessibilityIdentifier("devices-rename-field")
                    } else {
                        Text(row.displayName)
                            .font(Theme.Fonts.body.weight(.medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(DevicesPresentation.rowSummary(row))
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                    statusLine(reachability)
                        .accessibilityIdentifier("devices-row-reachability")
                    if let check {
                        statusLine(check)
                            .accessibilityIdentifier("devices-row-delivery-check")
                    }
                }
                Spacer(minLength: Theme.Spacing.md)
                if isRenaming {
                    Button(appLocalized("Cancel")) { model.cancelRename() }
                        .buttonStyle(.secondaryAction)
                        .keyboardShortcut(.cancelAction)
                    Button(appLocalized("Save")) { Task { await model.saveRename() } }
                        .buttonStyle(.secondaryAction)
                        .dimmedAndDisabled(!model.canSaveRename)
                        .accessibilityIdentifier("devices-rename-save")
                } else {
                    Button(appLocalized("Rename")) { model.beginRename(row) }
                        .buttonStyle(.secondaryAction)
                        .accessibilityIdentifier("devices-rename")
                    Button(appLocalized("Test Delivery")) { Task { await model.testDelivery(row) } }
                        .buttonStyle(.secondaryAction)
                        .dimmedAndDisabled(!model.canTestDelivery)
                        .accessibilityIdentifier("devices-test-delivery")
                    Button(appLocalized("Remove"), role: .destructive) { model.requestRemoval(row) }
                        .buttonStyle(.irreversibleAction)
                        .dimmedAndDisabled(model.removalCandidate == row.id)
                        .accessibilityIdentifier("devices-remove")
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            if model.removalCandidate == row.id {
                GroupedListSeparator()
                DevicesConfirmationRow(warning: DevicesPresentation.removalWarning(row.displayName)) {
                    Button(appLocalized("Cancel")) { model.cancelRemoval() }
                        .buttonStyle(.secondaryAction)
                    Button(appLocalized("Remove"), role: .destructive) { Task { await model.confirmRemoval() } }
                        .buttonStyle(FrozenDangerButtonStyle())
                        .accessibilityIdentifier("devices-confirm-remove")
                }
            }
        }
    }

    private func statusLine(_ line: DevicesPresentation.Notice) -> some View {
        Text(line.text)
            .font(Theme.Fonts.secondary)
            .foregroundStyle(line.isWarning ? Theme.warning : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A Settings row whose message turns to the warning role when it explains
/// why something is unavailable.
private struct DevicesSettingRow<Control: View>: View {
    let title: String
    let message: String
    let isWarning: Bool
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(isWarning ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-devices-notice")
            }
            Spacer(minLength: Theme.Spacing.md)
            control
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(minHeight: 44)
    }
}

/// The inline confirmation used across Settings: a warning glyph, the
/// consequence, and the actions on the subtle warning surface.
private struct DevicesConfirmationRow<Actions: View>: View {
    let warning: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(warning)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.md)
            actions
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.warningSubtle)
    }
}

private extension View {
    /// The shared secondary button styles draw the same when disabled, so an
    /// unavailable Devices action is also dimmed.
    func dimmedAndDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.45 : 1)
    }
}
