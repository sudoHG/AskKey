import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialEditorView {
    var componentEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if template == .custom {
                Text(FrozenEditorCopy.customHelp)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
                customKeyTable
            } else {
                VStack(spacing: 0) {
                    ForEach($components) { $component in
                        templateRow($component)
                            .overlay(alignment: .top) {
                                if component.id != components.first?.id {
                                    Rectangle().fill(Theme.separator).frame(height: 1)
                                }
                            }
                    }
                }
                .credentialGroupedListStyle()
            }
            HStack(spacing: Theme.Spacing.sm) {
                if template == .custom {
                    Button(FrozenEditorCopy.addTextAction) {
                        components.append(CredentialComponentDraft())
                    }
                    .buttonStyle(.bordered)
                    Button(FrozenEditorCopy.addFileAction) {
                        components.append(CredentialComponentDraft(kind: .file))
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        components.append(CredentialComponentDraft(isCustomKey: true))
                    } label: {
                        Label(FrozenEditorCopy.kindLabel(for: .text), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(appLocalized("Add text"))
                    Button {
                        components.append(CredentialComponentDraft(kind: .file, isCustomKey: true))
                    } label: {
                        Label(FrozenEditorCopy.kindLabel(for: .file), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(appLocalized("Add file"))
                }
            }
            DisclosureGroup(appLocalized("Delivery Options")) {
                ForEach($components) { $component in
                    if !component.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        CredentialComponentDeliveryEditor(component: $component)
                    }
                }
            }
            .font(Theme.Fonts.caption)
        }
    }

    private var customKeyTable: some View {
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
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)

            ForEach($components) { $component in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        TextField(appLocalized("Key, for example API_TOKEN"), text: $component.name)
                            .font(Theme.Fonts.mono)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(componentEditorIdentifier(component, field: "name"))
                        if FrozenEditorCopy.deliveryLabel(for: component) != component.name {
                            deliveryTag(component)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        if component.kind == .file {
                            fileButton(component, title: appLocalized("Choose File…"))
                        } else {
                            TextField(appLocalized("Enter text value"), text: $component.text)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(FrozenEditorCopy.kindLabel(for: component.kind))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 42, height: 22)
                    if components.count > 1 {
                        Button(role: .destructive) {
                            components.removeAll { $0.id == component.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 18, height: 22)
                        .accessibilityLabel(appLocalized("Remove"))
                    } else {
                        Color.clear.frame(width: 18, height: 1)
                    }
                }
                .padding(Theme.Spacing.md)
                .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
            }
        }
        .credentialGroupedListStyle()
    }

    private func templateRow(_ component: Binding<CredentialComponentDraft>) -> some View {
        let draft = component.wrappedValue
        let title = CredentialTemplate.fieldTitle(for: draft.name)
        let help = FrozenEditorCopy.fieldCard(for: draft).help
        let isRevealed = revealedComponentIDs.contains(draft.id)
        return HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if draft.isCustomKey {
                    TextField(appLocalized("Key, for example API_TOKEN"), text: component.name)
                        .font(Theme.Fonts.mono)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(componentEditorIdentifier(draft, field: "name"))
                    if FrozenEditorCopy.deliveryLabel(for: draft) != draft.name {
                        deliveryTag(draft)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(title)
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.text)
                        if draft.isOptional {
                            Text(appLocalized("Optional"))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .help(help)
                    deliveryTag(draft)
                }
            }
            .frame(width: 180, alignment: .leading)
            Group {
                if draft.kind == .file {
                    fileButton(draft, title: appLocalized("Choose file"))
                } else if CredentialEditorInteractionPresentation.inputVisibility(
                    template: template,
                    isSecret: draft.isSecret,
                    isRevealed: isRevealed
                ) == .plain {
                    TextField(FrozenEditorCopy.placeholder(for: draft), text: component.text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(componentEditorIdentifier(draft, field: "value"))
                } else {
                    SecureField(FrozenEditorCopy.placeholder(for: draft), text: component.text)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(componentEditorIdentifier(draft, field: "value"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if draft.isSecret {
                componentRevealButton(draft.id)
                if !isRevealed {
                    Text(FrozenEditorCopy.contentHiddenLabel)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if draft.isRemovable {
                Button(appLocalized("Remove")) {
                    components.removeAll { $0.id == draft.id }
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private func deliveryTag(_ component: CredentialComponentDraft) -> some View {
        Text(verbatim: FrozenEditorCopy.deliveryLabel(for: component))
            .font(Theme.Fonts.mono)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
            .accessibilityLabel(appLocalizedFormat("Delivered as %@", FrozenEditorCopy.deliveryLabel(for: component)))
    }

    private func fileButton(_ component: CredentialComponentDraft, title: String) -> some View {
        Button(component.file?.originalFilename ?? title) {
            chooseComponentFile(component.id)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(componentEditorIdentifier(component, field: "value"))
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
