import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialEditorView {
    @ViewBuilder
    var filePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button(appLocalized(snapshot == nil && credential == nil ? CredentialManagementCopy.chooseFile : CredentialManagementCopy.replaceFile)) {
                chooseFile()
            }
            if let snapshot {
                Text(snapshot.originalFilename)
                    .font(Theme.Fonts.mono)
                Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteSize), countStyle: .file))
                    .foregroundStyle(Theme.textSecondary)
                Text(snapshot.contentDigest.map { String(format: "%02x", $0) }.joined())
                    .font(Theme.Fonts.caption)
                    .textSelection(.enabled)
            } else if let credential, credential.payloadKind == .file {
                Text("••••")
                    .foregroundStyle(Theme.textSecondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(credential.byteSize ?? 0), countStyle: .file))
                    .foregroundStyle(Theme.textSecondary)
                Text(credential.contentDigest ?? "")
                    .font(Theme.Fonts.caption)
                    .textSelection(.enabled)
            }
        }
    }

    private func chooseFile() {
        guard let url = chooseFileURL() else { return }
        do {
            let frozen = try FileImport.freeze(url: url)
            snapshot = frozen
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = frozen.originalFilename
            }
        } catch {
            vault.presentError(error)
        }
    }

    func chooseFileURL() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = appLocalized("Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

}
