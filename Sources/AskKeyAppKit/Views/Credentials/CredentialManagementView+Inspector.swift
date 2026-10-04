import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    @ViewBuilder
    var credentialInspector: some View {
        if let credential = filteredCredentials.first(where: { $0.id == selectedCredentialID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(credential.name)
                                .font(Theme.Fonts.title)
                                .foregroundStyle(Theme.text)
                            Text(appLocalizedFormat("%lld items are delivered together after one approval.", max(credential.components.count, 1)))
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if deletingCredential?.id == credential.id {
                            Button(FrozenDangerActions.credentialConfirmationTitle, role: .destructive) {
                                vault.deleteTextCredential(credential)
                                deletingCredential = nil
                                selectedCredentialID = nil
                            }
                            .buttonStyle(FrozenDangerButtonStyle())
                            .accessibilityIdentifier("credential-delete-confirm-\(credential.id)")
                            Button(appLocalized("Keep")) { deletingCredential = nil }
                        } else {
                            Button(appLocalized("Edit")) {
                                route = .editor(template: .custom, credentialID: credential.id)
                            }
                            .accessibilityIdentifier("credential-edit-\(credential.id)")
                            Button(appLocalized("Delete…"), role: .destructive) { deletingCredential = credential }
                                .foregroundStyle(Theme.warning)
                                .tint(Theme.warning)
                                .accessibilityIdentifier("credential-delete-\(credential.id)")
                        }
                    }

                    if deletingCredential?.id == credential.id {
                        inlineWarning(appLocalized("Deleted credentials remain recoverable in the Recycle Bin for 30 days. Permanent deletion is available only there."))
                    }

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(FrozenCredentialDetailCopy.protectionTitle)
                                .font(Theme.Fonts.body.weight(.semibold))
                            Text(FrozenCredentialDetailCopy.protectionMessage)
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(
                            vault.revealedCredential?.id == credential.id
                                ? appLocalized("Hide Plaintext")
                                : appLocalized("Authenticate and Reveal")
                        ) {
                            Task { @MainActor in
                                if vault.revealedCredential?.id == credential.id {
                                    vault.revealedCredential = nil
                                } else {
                                    _ = await vault.revealTextCredential(credential)
                                }
                            }
                        }
                        .buttonStyle(FrozenPrimaryButtonStyle())
                        if credential.payloadKind != .bundle {
                            Button(appLocalized("Authenticate and Copy")) {
                                vault.copyTextCredentialValue(credential)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(14)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    VStack(alignment: .leading, spacing: 0) {
                        if credential.payloadKind == .bundle {
                            ForEach(credential.components, id: \.name) { component in
                                HStack {
                                    Text(CredentialTemplate.fieldTitle(for: component.name))
                                        .font(Theme.Fonts.secondary.weight(.semibold))
                                    Spacer()
                                    Text(componentDisplayValue(component, credentialID: credential.id))
                                        .font(Theme.Fonts.mono)
                                        .foregroundStyle(Theme.textSecondary)
                                    Button(appLocalized("Copy")) {
                                        vault.copyCredentialComponent(
                                            credential,
                                            componentName: component.name
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.accent)
                                    credentialTag(componentDisplayKind(component))
                                }
                                .padding(Theme.Spacing.md)
                                .overlay(alignment: .top) { Divider() }
                            }
                        } else {
                            HStack {
                                Text(credential.payloadKind == .file ? appLocalized("File") : appLocalized("Value"))
                                    .font(Theme.Fonts.secondary.weight(.semibold))
                                Spacer()
                                Text(vault.revealedCredential?.id == credential.id ? appLocalized("Revealed") : "••••••••")
                                    .font(Theme.Fonts.mono)
                            }
                            .padding(Theme.Spacing.md)
                        }
                    }
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack {
                            Text(appLocalized("Group"))
                                .font(Theme.Fonts.caption.weight(.semibold))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Picker(appLocalized("Group"), selection: Binding(
                                get: { credential.groupName ?? "" },
                                set: { vault.moveCredential(credential, toGroup: $0.isEmpty ? nil : $0) }
                            )) {
                                Text(appLocalized("Ungrouped")).tag("")
                                ForEach(vault.credentialGroups, id: \.self) { group in
                                    Text(group).tag(group)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 180)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let _ = allowanceRefresh
                            if let deadline = vault.timedAllowanceDeadline(for: credential.id),
                               deadline > context.date {
                                HStack {
                                    Text(appLocalized("Timed allow remaining ") + FrozenCountdown.format(deadline: deadline, now: context.date))
                                        .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                    Button(appLocalized("Revoke Now")) {
                                        _ = vault.revokeTimedAllowance(for: credential.id)
                                        allowanceRefresh += 1
                                    }
                                    .accessibilityIdentifier("credential-revoke-timed-allowance")
                                }
                            }
                        }
                        Text(appLocalized("Agent Permission"))
                            .font(Theme.Fonts.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                        FrozenSegmentedControl(
                            options: CredentialPermission.prototypeCases.map { ($0, $0.prototypeTitle) },
                            selection: Binding(
                                get: { credential.permission },
                                set: { vault.updateCredentialPermission(credential, permission: $0) }
                            )
                        )
                    }
                    .padding(14)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)

                    if !credential.usageInstructions.isEmpty {
                        labeled(appLocalized("Instructions for Agent"), credential.usageInstructions)
                    }

                    if vault.revealedCredential?.id == credential.id,
                       credential.payloadKind != .bundle {
                        if credential.payloadKind == .file {
                            revealedFileBody(vault.revealedCredential?.fileBytes)
                        } else if let value = vault.revealedCredential?.value {
                            Text(value)
                                .font(Theme.Fonts.mono)
                                .textSelection(.enabled)
                                .padding(Theme.Spacing.md)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.neutralSubtle, in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .padding(28)
            }
        } else {
            VStack {
                Spacer()
                Text(appLocalized("Select a credential"))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func componentDisplayValue(
        _ component: ManagedCredentialComponent,
        credentialID: String
    ) -> String {
        guard vault.revealedCredential?.id == credentialID,
              let revealed = vault.revealedCredential?.components.first(where: {
                  $0.name == component.name
              }) else { return "••••••••" }
        switch revealed.value {
        case .text(let value): return value
        case .file(let filename, let bytes):
            return "\(filename) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file))"
        case nil: return appLocalized("Unavailable")
        }
    }

    private func componentDisplayKind(_ component: ManagedCredentialComponent) -> String {
        guard let revealed = vault.revealedCredential?.components.first(where: {
            $0.name == component.name
        }) else {
            return FrozenCredentialDetailCopy.kindLabel(
                componentName: component.name,
                kind: component.kind
            )
        }
        switch revealed.value {
        case .text: return appLocalized("Text")
        case .file: return appLocalized("File")
        case nil: return appLocalized("Protected")
        }
    }

    @ViewBuilder
    private func revealedFileBody(_ bytes: Data?) -> some View {
        if let bytes, let text = String(data: bytes, encoding: .utf8) {
            Text(text)
                .font(Theme.Fonts.mono)
                .textSelection(.enabled)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.neutralSubtle, in: .rect(cornerRadius: 8))
        } else {
            Text(appLocalized("Binary file"))
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.neutralSubtle, in: .rect(cornerRadius: 8))
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.text)
        }
    }

}
