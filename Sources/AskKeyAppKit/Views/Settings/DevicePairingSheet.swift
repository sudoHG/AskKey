import AskKeyDevices
import SwiftUI

/// The **Pair a Device…** sheet (ADR 0013 → Pairing): the QR code, then the
/// device that scanned it, then the code the iPhone shows, then the result.
/// It never shows the Mac's code: no state it reads carries one.
struct DevicePairingSheet: View {
    @Bindable var model: DevicesSettingsModel
    /// The last state, kept while the sheet animates away after the session closed.
    @State private var shown: PairingSheetPresentation?
    @FocusState private var codeFocused: Bool

    var body: some View {
        let _ = AppLanguage.store.resolved
        let sheet = model.sheet ?? shown
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
        .onAppear { shown = model.sheet }
        .onChange(of: model.sheet) { _, new in
            if let new { shown = new }
        }
    }

    @ViewBuilder
    private func content(_ sheet: PairingSheetPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            switch sheet.stage {
            case .preparing:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .qrCode(let text, let expiresAt):
                qrCode(text: text, expiresAt: expiresAt)
            default:
                EmptyView()
            }
            if let peer = sheet.peer {
                peerCard(peer, isWaiting: sheet.stage == .waitingForIPhone
                    || sheet.stage == .waitingForIPhoneConfirmation)
            }
            if sheet.stage == .codeEntry(accepted: false) {
                codeField
            }
            if let feedback = sheet.feedback {
                Text(feedback)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(sheet.feedbackIsWarning ? Theme.warning : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("devices-pairing-feedback")
            }
            if let notice = sheet.notice {
                BackupNotice(text: notice)
            }
        }
    }

    private func qrCode(text: String, expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let expired = context.date >= expiresAt
            VStack(spacing: Theme.Spacing.sm) {
                if expired {
                    Text(appLocalized("This QR code has expired. Pair again to get a new one."))
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if let image = model.qrImage(for: text) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 184, height: 184)
                        .padding(Theme.Spacing.md)
                        .background(Color.white, in: .rect(cornerRadius: Theme.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.separator))
                        // The label names the image only; the payload holds the pairing secret.
                        .accessibilityLabel(appLocalized("QR code for pairing"))
                        .accessibilityIdentifier("devices-pairing-qr")
                    Text(appLocalizedFormat("Expires in %@", FrozenCountdown.format(deadline: expiresAt, now: context.date)))
                        .font(Theme.Fonts.secondary.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func peerCard(_ peer: PairingPeer, isWaiting: Bool) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: DevicesPresentation.platformSymbol(peer.platform))
                .font(Theme.Icon.inlineStatus)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(appLocalized("Device that scanned the QR code"))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.textTertiary)
                Text(peer.displayName)
                    .font(Theme.Fonts.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(PairingSheetPresentation.peerPlatform(peer))
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            if isWaiting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityIdentifier("devices-pairing-waiting")
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
    }

    /// The person's entry of the iPhone's code. Not a one-time-code field and
    /// no autofill or completion: the code must come from the iPhone's
    /// pairing screen. The entry is never cut short.
    private var codeField: some View {
        CredentialFormField(appLocalized("Pairing code")) {
            TextField(appLocalized("6 digits"), text: $model.codeEntry)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Fonts.headline.monospacedDigit())
                .textContentType(nil)
                .autocorrectionDisabled()
                .frame(width: 180)
                .focused($codeFocused)
                .onSubmit { Task { await model.confirm() } }
                .onAppear { codeFocused = true }
                .accessibilityLabel(appLocalized("Pairing code shown on the iPhone"))
                .accessibilityIdentifier("devices-pairing-code")
        }
    }

    @ViewBuilder
    private func actions(_ sheet: PairingSheetPresentation) -> some View {
        Spacer(minLength: 0)
        switch sheet.stage {
        case .paired:
            Button(appLocalized("Done")) { Task { await model.closeSheet() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("devices-pairing-done")
        case .ended(let canPairAgain):
            Button(appLocalized("Close")) { Task { await model.closeSheet() } }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("devices-pairing-close")
            if canPairAgain { pairAgainButton }
        case .failed:
            Button(appLocalized("Close")) { Task { await model.closeSheet() } }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("devices-pairing-close")
        case .codeEntry:
            cancelButton
            Button(appLocalized("Confirm")) { Task { await model.confirm() } }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConfirm)
                .accessibilityIdentifier("devices-pairing-confirm")
        case .qrCode(_, let expiresAt):
            cancelButton
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date >= expiresAt { pairAgainButton }
            }
        case .preparing, .waitingForIPhone, .waitingForIPhoneConfirmation:
            cancelButton
        }
    }

    private var cancelButton: some View {
        Button(appLocalized("Cancel")) { Task { await model.closeSheet() } }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("devices-pairing-cancel")
    }

    private var pairAgainButton: some View {
        Button(appLocalized("Pair Again")) { Task { await model.pairAgain() } }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("devices-pairing-again")
    }
}
