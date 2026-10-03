import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialEditorView {
    @ViewBuilder
    var filePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(appLocalized(snapshot == nil && credential == nil ? CredentialManagementCopy.chooseFile : CredentialManagementCopy.replaceFile)) {
                chooseFile()
            }
            if let snapshot {
                Text(snapshot.originalFilename)
                    .font(.system(.body, design: .monospaced))
                Text(ByteCountFormatter.string(fromByteCount: Int64(snapshot.byteSize), countStyle: .file))
                    .foregroundStyle(.secondary)
                Text(snapshot.contentDigest.map { String(format: "%02x", $0) }.joined())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else if let credential, credential.payloadKind == .file {
                Text("••••")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: Int64(credential.byteSize ?? 0), countStyle: .file))
                    .foregroundStyle(.secondary)
                Text(credential.contentDigest ?? "")
                    .font(.system(.caption, design: .monospaced))
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
