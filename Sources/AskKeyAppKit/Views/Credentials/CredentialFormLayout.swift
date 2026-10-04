import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

/// A labeled form field: a secondary-size label above its control.
struct CredentialFormField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Fonts.secondary.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

/// The single back link above a page title.
struct CredentialBackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.left")
                    .font(Theme.Fonts.caption.weight(.semibold))
                Text(title)
                    .font(Theme.Fonts.body)
            }
            .foregroundStyle(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The fixed bottom bar of the create and import pages: Cancel and one primary action.
struct CredentialFormBottomBar: View {
    let primaryTitle: String
    let primaryIdentifier: String
    let isPrimaryDisabled: Bool
    let onCancel: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
            HStack(spacing: Theme.Spacing.md) {
                Spacer()
                Button(appLocalized("Cancel"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPrimaryDisabled)
                    .accessibilityIdentifier(primaryIdentifier)
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.md)
        }
        .background(Theme.windowBackground)
    }
}

/// The Agent permission segmented control with a one-line explanation of the selection.
struct CredentialPermissionPicker: View {
    @Binding var permission: CredentialPermission

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Picker(appLocalized("Agent Permission"), selection: $permission) {
                ForEach(CredentialPermission.prototypeCases, id: \.self) { option in
                    Text(option.editorTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .accessibilityIdentifier("credential-permission")
            Text(permission.editorExplanation)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

extension CredentialPermission {
    /// The segment title in the create and import forms.
    var editorTitle: String {
        switch self {
        case .ask: return appLocalized("Ask every time")
        case .allowed: return appLocalized("Allow")
        case .hidden: return appLocalized("Hidden")
        }
    }

    var editorExplanation: String {
        switch self {
        case .ask: return appLocalized("Agents ask you before every use of this credential. Recommended.")
        case .allowed: return appLocalized("Agents can use this credential without asking you.")
        case .hidden: return appLocalized("Agents cannot see this credential or ask to use it.")
        }
    }
}

extension View {
    /// Pins the bottom bar below the scrolling form so it stays fixed at the window edge.
    func credentialFormBottomBar(_ bar: CredentialFormBottomBar) -> some View {
        VStack(spacing: 0) {
            self
            bar
        }
    }

    /// Surface, separator stroke and group radius of a grouped list.
    func credentialGroupedListStyle() -> some View {
        background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.separator))
    }
}
