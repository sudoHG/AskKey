import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenFileImportMapping {
    static func component(from file: FileImport.FrozenFile) -> CredentialComponentInput {
        .init(
            name: "FILE",
            value: .file(filename: file.originalFilename, bytes: file.bytes)
        )
    }
}
