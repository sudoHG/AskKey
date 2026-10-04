import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialEditorView {
    var componentEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(template == .custom
                 ? FrozenEditorCopy.customHelp
                 : appLocalized("Keep everything needed for one task together."))
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
            DisclosureGroup(appLocalized("Delivery Options")) {
                ForEach($components) { $component in
                    if !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CredentialComponentDeliveryEditor(component: $component)
                    }
                }
            }
            .font(Theme.Fonts.caption)
            if template == .custom {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(FrozenEditorCopy.keyHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(FrozenEditorCopy.valueHeader)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 42, height: 1)
                        Color.clear.frame(width: 18, height: 1)
                    }
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.Spacing.sm)

                    ForEach($components) { $component in
                        HStack(spacing: 10) {
                            TextField(appLocalized("Key, for example API_TOKEN"), text: $component.name)
                                .font(Theme.Fonts.mono)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "name"))
                            if component.kind == .file {
                                Button(component.file?.originalFilename ?? appLocalized("Choose File…")) {
                                    chooseComponentFile(component.id)
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else {
                                TextField(appLocalized("Enter text value"), text: $component.text)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            }
                            Text(FrozenEditorCopy.kindLabel(for: component.kind))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 42)
                            if components.count > 1 {
                                Button(role: .destructive) {
                                    components.removeAll { $0.id == component.id }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 18)
                            } else {
                                Color.clear.frame(width: 18, height: 1)
                            }
                        }
                        .padding(10)
                        .overlay(alignment: .top) { Divider() }
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
            } else if template == .api {
                ForEach($components) { $component in
                    let card = FrozenEditorCopy.fieldCard(for: component)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title)
                                    .font(Theme.Fonts.secondary.weight(.semibold))
                                if !card.help.isEmpty {
                                    Text(card.help)
                                        .font(Theme.Fonts.secondary)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            }
                            Spacer()
                            if component.isRemovable {
                                Button(appLocalized("Remove"), role: .destructive) {
                                    components.removeAll { $0.id == component.id }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        HStack(spacing: Theme.Spacing.sm) {
                            if component.kind == .file {
                                Button(component.file?.originalFilename ?? appLocalized("Choose file")) {
                                    chooseComponentFile(component.id)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else if CredentialEditorInteractionPresentation.inputVisibility(
                                template: template,
                                isSecret: component.isSecret,
                                isRevealed: revealedComponentIDs.contains(component.id)
                            ) == .plain {
                                TextField(
                                    appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                    text: $component.text
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            } else {
                                SecureField(
                                    appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                    text: $component.text
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                            }
                            if component.isSecret {
                                componentRevealButton(component.id)
                            }
                            Text(FrozenEditorCopy.kindLabel(for: component))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                }
            } else {
                ForEach($components) { $component in
                    HStack {
                        Text(CredentialTemplate.fieldTitle(for: component.name))
                            .font(Theme.Fonts.secondary.weight(.semibold))
                            .frame(minWidth: 100, alignment: .leading)
                        if component.kind == .file {
                            Button(component.file?.originalFilename ?? appLocalized("Choose file")) {
                                chooseComponentFile(component.id)
                            }
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        } else if CredentialEditorInteractionPresentation.inputVisibility(
                            template: template,
                            isSecret: component.isSecret,
                            isRevealed: revealedComponentIDs.contains(component.id)
                        ) == .plain {
                            TextField(
                                appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                text: $component.text
                            )
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        } else {
                            SecureField(
                                appLocalizedFormat("Enter %@", CredentialTemplate.fieldTitle(for: component.name)),
                                text: $component.text
                            )
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        }
                        if component.isSecret {
                            componentRevealButton(component.id)
                        }
                        Text(FrozenEditorCopy.kindLabel(for: component))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 42)
                        if component.isRemovable {
                            Button(role: .destructive) {
                                components.removeAll { $0.id == component.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Button(template == .custom ? FrozenEditorCopy.addTextAction : appLocalized("Add text")) {
                    components.append(CredentialComponentDraft())
                }
                .buttonStyle(.bordered)
                Button(template == .custom ? FrozenEditorCopy.addFileAction : appLocalized("Add file")) {
                    components.append(CredentialComponentDraft(kind: .file))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func componentEditorIdentifier(
        _ component: CredentialComponentDraft,
        field: String
    ) -> String {
        let index = components.firstIndex(where: { $0.id == component.id }) ?? 0
        return "credential-editor-component-\(field)-\(index)"
    }

    private func chooseComponentFile(_ id: UUID) {
        guard let url = chooseFileURL() else { return }
        do {
            if url.lastPathComponent == ".env" || url.pathExtension.lowercased() == "env" {
                let pairs = try FrozenEnvImport.load(url: url).pairs
                guard !pairs.isEmpty else {
                    vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
                    return
                }
                components = pairs.map { CredentialComponentDraft(name: $0.name, text: $0.value) }
                isEnvImport = true
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = appLocalized("Imported environment variables")
                }
                return
            }
            let frozen = try FileImport.freeze(url: url)
            guard let index = components.firstIndex(where: { $0.id == id }) else { return }
            components[index].file = frozen
        } catch {
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func toggleComponentReveal(_ id: UUID) {
        if revealedComponentIDs.contains(id) {
            revealedComponentIDs.remove(id)
        } else {
            revealedComponentIDs.insert(id)
        }
    }

    private func componentRevealButton(_ id: UUID) -> some View {
        let isRevealed = revealedComponentIDs.contains(id)
        return Button {
            toggleComponentReveal(id)
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRevealed ? appLocalized("Hide Content") : appLocalized("Show Content"))
    }

}
