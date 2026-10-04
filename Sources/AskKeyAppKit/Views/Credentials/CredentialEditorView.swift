import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialEditorView: View {
    let credential: ManagedTextCredential?
    let onClose: (() -> Void)?

    @Environment(VaultViewModel.self) var vault
    @Environment(\.dismiss) var dismiss
    @State var name: String
    @State var value: String
    @State var usageInstructions: String
    @State var privateNotes: String
    @State var groupName: String
    @State var environmentVariable: String
    @State var permission: CredentialPermission
    @State var expiryDateText: String
    @State private var revealed = false
    @State var revealedComponentIDs: Set<UUID> = []
    @State var payloadKind: CredentialPayloadKind
    @State var snapshot: FileImport.FrozenFile?
    @State var didLoadSecrets = false
    @State var template = CredentialTemplate.custom
    @State var components: [CredentialComponentDraft]
    @State var isEnvImport = false
    @State var importConflictChoice = FrozenImportConflictChoice.skip
    @State private var moreExpanded = false

    init(
        credential: ManagedTextCredential?,
        preferredKind: CredentialPayloadKind = .text,
        preferredGroup: String? = nil,
        initialTemplate: CredentialTemplate = .custom,
        initialMoreExpanded: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        self.credential = credential
        self.onClose = onClose
        _name = State(initialValue: credential?.name ?? "")
        _value = State(initialValue: "")
        _usageInstructions = State(initialValue: credential?.usageInstructions ?? "")
        _privateNotes = State(initialValue: "")
        _groupName = State(initialValue: credential?.groupName ?? preferredGroup ?? "")
        _environmentVariable = State(initialValue: credential?.environmentVariable ?? "")
        _moreExpanded = State(initialValue: initialMoreExpanded)
        _permission = State(initialValue: credential?.permission ?? .ask)
        _expiryDateText = State(initialValue: credential?.expiresAt.map(
            FrozenEditorMoreSettingsPresentation.expiryText
        ) ?? "")
        _payloadKind = State(initialValue: credential?.payloadKind ?? preferredKind)
        if let credential, credential.payloadKind == .bundle {
            let inferred = CredentialTemplate.prototypeTemplate(
                componentNames: Set(credential.components.map(\.name))
            )
            _template = State(initialValue: inferred)
            _components = State(initialValue: credential.components.map { component in
                var draft = inferred.components.first(where: { $0.name == component.name })
                    ?? CredentialComponentDraft(name: component.name)
                draft.kind = component.kind
                draft.delivery = component.delivery
                draft.masked = component.masked
                return draft
            })
        } else {
            _template = State(initialValue: initialTemplate)
            _components = State(initialValue: preferredKind == .file
                ? [CredentialComponentDraft(kind: .file), CredentialComponentDraft(isOptional: true)]
                : initialTemplate.components)
        }
    }

    private var isValid: Bool {
        let named = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expiryIsValid = expiryDateText.isEmpty || parsedExpiryDate != nil
        if credential != nil, !didLoadSecrets {
            return named && expiryIsValid
        }
        if credential == nil || payloadKind == .bundle {
            return named
                && CredentialEditorComponentValidation.canSave(components)
                && (credential == nil || didLoadSecrets)
                && expiryIsValid
        }
        if payloadKind == .file {
            let hasFile = snapshot != nil || credential?.payloadKind == .file
            return named && hasFile && (credential == nil || didLoadSecrets) && expiryIsValid
        }
        return named && !value.isEmpty && expiryIsValid
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Button(credential == nil ? appLocalized("← Choose Again") : appLocalized("← Cancel Editing")) { close() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(credential == nil ? appLocalized("New Credential") : appLocalized("Edit Credential"))
                        .font(Theme.Fonts.title)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(template.prototypeTitle) · " + appLocalized("Its contents are saved and authorized as one set."))
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                }
                editorField(appLocalized("Credential Name")) {
                    TextField(appLocalized("For example: Production API"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("credential-editor-name")
                }
                editorField(appLocalized("Agent Permission")) { permissionSegments }
                editorField(appLocalized("This Credential Contains")) {
                    if credential != nil, !didLoadSecrets {
                        HStack {
                            Text(appLocalized("Contents stay hidden. Changing the name, group, or permission does not reveal plaintext."))
                                .font(Theme.Fonts.secondary)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button(appLocalized("Authenticate to Edit Contents")) {
                                Task { await loadExistingSecrets() }
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(Theme.Spacing.md)
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    } else if credential == nil || payloadKind == .bundle {
                        componentEditor
                    } else if payloadKind == .file {
                        filePicker
                    } else {
                        HStack {
                            if revealed {
                                TextField(appLocalized("Value"), text: $value)
                                    .accessibilityIdentifier("credential-editor-value")
                            } else {
                                SecureField(appLocalized("Value"), text: $value)
                                    .accessibilityIdentifier("credential-editor-value")
                            }
                            Button { revealed.toggle() } label: {
                                Image(systemName: revealed ? "eye.slash" : "eye")
                            }.buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        moreExpanded.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(Theme.Fonts.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .rotationEffect(.degrees(moreExpanded ? 90 : 0))
                            Text(appLocalized("More Settings"))
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("credential-more-settings")
                    if moreExpanded {
                        VStack(alignment: .leading, spacing: 10) {
                            editorField(FrozenEditorMoreSettingsPresentation.agentInstructionsLabel) {
                                TextField(appLocalized("For example: App Store releases only"), text: $usageInstructions, axis: .vertical)
                            }
                            editorField(FrozenEditorMoreSettingsPresentation.privateNotesLabel) {
                                TextField(appLocalized("Only you can see this"), text: $privateNotes, axis: .vertical)
                                    .accessibilityIdentifier("credential-private-notes")
                                    .disabled(credential != nil && !didLoadSecrets)
                                if credential != nil && !didLoadSecrets {
                                    Button(appLocalized("Authenticate to Edit Private Notes")) {
                                        Task { await loadExistingSecrets() }
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            editorField(FrozenEditorMoreSettingsPresentation.expiryLabel) {
                                TextField("YYYY-MM-DD", text: $expiryDateText)
                                    .textFieldStyle(.roundedBorder)
                                Text(FrozenEditorMoreSettingsPresentation.expiryHelp)
                                    .font(Theme.Fonts.secondary)
                                    .foregroundStyle(
                                        expiryDateText.isEmpty || parsedExpiryDate != nil
                                            ? Theme.textSecondary
                                            : Theme.warning
                                    )
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .font(Theme.Fonts.secondary.weight(.semibold))
                if let existingImportCredential {
                    let conflict = FrozenImportConflictPresentation(
                        existingName: existingImportCredential.name,
                        choice: importConflictChoice
                    )
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.warning)
                        Text(conflict.warning ?? "")
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warningSubtle, in: .rect(cornerRadius: 9))
                    FrozenSegmentedControl(
                        options: Array(zip(FrozenImportConflictChoice.allCases, conflict.choices)),
                        selection: $importConflictChoice
                    )
                }
                HStack {
                    Spacer()
                    Button(appLocalized("Cancel")) { close() }
                    Button(credential == nil ? appLocalized("Save Credential") : appLocalized("Save Changes")) { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                        .accessibilityIdentifier("credential-editor-save")
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }

    @MainActor
    private func loadExistingSecrets() async {
        guard let credential, !didLoadSecrets else { return }
        if let revealed = await vault.revealTextCredential(credential) {
                value = revealed.value ?? ""
                privateNotes = revealed.privateNotes ?? ""
                if revealed.payloadKind == .bundle {
                    do {
                        components = try CredentialEditorComponentLoader.load(
                            revealed.components,
                            template: template
                        )
                    } catch {
                        vault.presentError(error)
                        return
                    }
                }
                didLoadSecrets = true
        }
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.Fonts.secondary.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }

    private var permissionSegments: some View {
        FrozenSegmentedControl(
            options: CredentialPermission.prototypeCases.map { ($0, $0.prototypeTitle) },
            selection: $permission
        )
    }

}
