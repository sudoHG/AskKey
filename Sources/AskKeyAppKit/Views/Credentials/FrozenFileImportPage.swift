import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct FrozenFileImportPage: View {
    let group: String?
    let onCancel: () -> Void
    let onSaved: () -> Void
    let onReplaced: (String) -> Void

    @Environment(VaultViewModel.self) private var vault
    @State private var source = ""
    @State private var name = FrozenImportCopy.defaultName
    @State private var sourceFileName: String?
    @State private var permission = CredentialPermission.ask
    @State private var preview: [(name: String, value: String)] = []
    @State private var importedFile: FileImport.FrozenFile?
    @State private var conflictChoice = FrozenImportConflictChoice.skip

    init(
        group: String?,
        previewValues: [(name: String, value: String)] = [],
        onCancel: @escaping () -> Void,
        onSaved: @escaping () -> Void,
        onReplaced: ((String) -> Void)? = nil
    ) {
        self.group = group
        self.onCancel = onCancel
        self.onSaved = onSaved
        self.onReplaced = onReplaced ?? { _ in onSaved() }
        _preview = State(initialValue: previewValues)
    }

    private var isPreviewing: Bool {
        !preview.isEmpty || importedFile != nil
    }

    var body: some View {
        if isPreviewing {
            previewPage
        } else {
            sourcePage
        }
    }

    private var sourcePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header(
                    back: onCancel,
                    subtitle: appLocalized("Supports regular files and .env files. The original is never modified.")
                )
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(appLocalized(".env File")).font(Theme.Fonts.body.weight(.semibold))
                    Text(appLocalized("Paste .env content below or choose a file. Multiple keys become items in one credential."))
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $source)
                        .font(Theme.Fonts.mono)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.separator))
                    HStack {
                        Button(appLocalized("Parse and Preview")) { parseSource() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button(appLocalized("Choose File…")) { chooseFile() }
                    }
                }
                .padding(Theme.Spacing.lg)
                .credentialGroupedListStyle()
            }
            .padding(Theme.Spacing.xxl)
        }
        .background(Theme.windowBackground)
    }

    private var previewPage: some View {
        let conflict = FrozenImportConflictPresentation(
            existingName: existingCredential?.name,
            choice: conflictChoice
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header(
                    back: returnToSource,
                    subtitle: importedFile == nil
                        ? FrozenImportCopy.previewSummary(
                            itemCount: preview.count,
                            skippedLineCount: skippedLineCount
                        )
                        : appLocalized("Contains 1 file. The original remains unchanged.")
                )
                CredentialFormField(appLocalized("Name")) {
                    TextField(appLocalized("Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("credential-import-name")
                    if sourceFileName != nil {
                        Text(FrozenImportCopy.nameHelp)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                CredentialFormField(appLocalized("Agent Permission")) {
                    CredentialPermissionPicker(permission: $permission)
                }
                CredentialFormField(
                    importedFile == nil ? FrozenImportCopy.contentsHeader : appLocalized("Contents")
                ) {
                    importedRows
                }
                if let warning = conflict.warning {
                    HStack(alignment: .top, spacing: 10) {
                        Text("⚠︎").foregroundStyle(Theme.warning)
                        Text(warning)
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warningSubtle, in: .rect(cornerRadius: 9))
                    FrozenSegmentedControl(
                        options: Array(zip(FrozenImportConflictChoice.allCases, conflict.choices)),
                        selection: $conflictChoice
                    )
                }
            }
            .padding(Theme.Spacing.xxl)
        }
        .credentialFormBottomBar(
            CredentialFormBottomBar(
                primaryTitle: conflict.confirmTitle,
                primaryIdentifier: "credential-import-confirm",
                isPrimaryDisabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onCancel: onCancel,
                onPrimary: save
            )
        )
        .background(Theme.windowBackground)
    }

    private func header(back: @escaping () -> Void, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            CredentialBackLink(title: appLocalized("Back"), action: back)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(appLocalized("Import from File"))
                    .font(Theme.Fonts.title)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var importedRows: some View {
        VStack(spacing: 0) {
            if let importedFile {
                FrozenImportTableLayout {
                    Text(appLocalized("File")).font(Theme.Fonts.body)
                    Text("\(importedFile.originalFilename) · \(ByteCountFormatter.string(fromByteCount: Int64(importedFile.byteSize), countStyle: .file))")
                        .font(Theme.Fonts.secondary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            } else {
                ForEach(Array(preview.enumerated()), id: \.offset) { index, item in
                    FrozenImportTableLayout {
                        Text(item.name).font(Theme.Fonts.mono)
                        FrozenImportedValue(value: item.value)
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
            }
        }
        .credentialGroupedListStyle()
    }

    private func returnToSource() {
        preview = []
        importedFile = nil
    }

    private func parseSource() {
        do {
            preview = try FrozenEnvImport.parse(source)
            if preview.isEmpty {
                vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
            }
        } catch {
            preview = []
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if url.lastPathComponent == ".env" || url.pathExtension.lowercased() == "env" {
                let imported = try FrozenEnvImport.load(url: url)
                source = imported.text
                let fileName = FrozenImportCopy.defaultName(forFileAt: url)
                if name == FrozenImportCopy.defaultName || name == sourceFileName { name = fileName }
                sourceFileName = fileName
                preview = imported.pairs
                if preview.isEmpty {
                    vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
                }
            } else {
                importedFile = try FileImport.freeze(url: url)
                name = url.lastPathComponent
                sourceFileName = url.lastPathComponent
            }
        } catch {
            vault.errorMessage = FrozenEnvImport.errorMessage(error)
        }
    }

    private func save() {
        let components: [CredentialComponentInput]
        if let importedFile {
            components = [FrozenFileImportMapping.component(from: importedFile)]
        } else {
            components = preview.map { .init(name: $0.name, value: .text($0.value)) }
        }
        let input = BundleCredentialInput(
            name: name,
            components: components,
            groupName: group,
            permission: permission
        )
        if let existingCredential {
            switch conflictChoice {
            case .skip:
                onSaved()
            case .replace:
                Task {
                    if await vault.replaceImportedBundleCredential(
                        id: existingCredential.id,
                        components: components
                    ) {
                        onReplaced(existingCredential.id)
                    }
                }
            }
            return
        }
        if vault.addBundleCredential(input) { onSaved() }
    }

    private var existingCredential: ManagedTextCredential? {
        let candidate = normalizedCredentialName(name)
        return vault.credentials.first {
            normalizedCredentialName($0.name) == candidate
        }
    }

    private var skippedLineCount: Int {
        FrozenImportCopy.blankLineCount(in: source)
    }

    private func normalizedCredentialName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
