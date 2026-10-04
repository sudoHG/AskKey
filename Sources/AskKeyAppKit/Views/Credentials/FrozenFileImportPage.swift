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
    @State private var name = appLocalized("Imported Environment Variables")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Button(appLocalized("← Back"), action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(appLocalized("Import from File")).font(Theme.Fonts.title)
                    Text(appLocalized("Supports regular files and .env files. The original is never modified."))
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.textSecondary)
                }

                if preview.isEmpty, importedFile == nil {
                    prototypeCard {
                        Text(appLocalized(".env File")).font(Theme.Fonts.body.weight(.semibold))
                        Text(appLocalized("Paste .env content below or choose a file. Multiple keys become items in one credential."))
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                        TextEditor(text: $source)
                            .font(Theme.Fonts.mono)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(Theme.neutral(0.045), in: .rect(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.neutral(0.08)))
                        HStack {
                            Button(appLocalized("Parse and Preview")) { parseSource() }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(appLocalized("Choose File…")) { chooseFile() }
                        }
                    }
                } else {
                    prototypeCard {
                        Text(appLocalized("Import Preview")).font(Theme.Fonts.body.weight(.semibold))
                        Text(importedFile == nil
                             ? FrozenImportCopy.previewSummary(
                                itemCount: preview.count,
                                skippedLineCount: skippedLineCount
                             )
                             : appLocalized("Contains 1 file. The original remains unchanged."))
                            .font(Theme.Fonts.secondary)
                            .foregroundStyle(Theme.textSecondary)
                        TextField(appLocalized("Credential Name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }
                    let conflict = FrozenImportConflictPresentation(
                        existingName: existingCredential?.name,
                        choice: conflictChoice
                    )
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
                    VStack(spacing: 0) {
                        FrozenImportTableLayout {
                            Text(appLocalized("Key"))
                            Text(appLocalized("Value"))
                        }
                        .font(Theme.Fonts.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(10)
                        if let importedFile {
                            FrozenImportTableLayout {
                                Text(appLocalized("File")).font(Theme.Fonts.secondary.weight(.semibold))
                                Text("\(importedFile.originalFilename) · \(ByteCountFormatter.string(fromByteCount: Int64(importedFile.byteSize), countStyle: .file))")
                                    .font(Theme.Fonts.secondary)
                            }
                            .padding(10)
                            .overlay(alignment: .top) { Divider() }
                        } else {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, item in
                            FrozenImportTableLayout {
                                Text(item.name).font(Theme.Fonts.mono.weight(.semibold))
                                FrozenImportedValue(value: item.value)
                            }
                            .padding(10)
                            .overlay(alignment: .top) { Divider() }
                        }
                        }
                    }
                    .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
                    .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
                    HStack {
                        Spacer()
                        Button(appLocalized("Back to Edit")) { preview = []; importedFile = nil }
                        Button(conflict.confirmTitle) { save() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(28)
        }
        .background(Theme.windowBackground)
    }

    private func prototypeCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.Radius.group))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.group).stroke(Theme.neutral(0.08)))
            .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
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
                if name == "导入的环境变量" { name = url.deletingPathExtension().lastPathComponent } // i18n-literal: Preserve the existing imported-credential name comparison.
                preview = imported.pairs
                if preview.isEmpty {
                    vault.errorMessage = appLocalized("The .env file contains no key-value pairs.")
                }
            } else {
                importedFile = try FileImport.freeze(url: url)
                name = url.lastPathComponent
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
            permission: .ask
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
        guard !source.isEmpty else { return 0 }
        return source.components(separatedBy: .newlines).filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func normalizedCredentialName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
