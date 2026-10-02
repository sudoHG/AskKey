import Foundation
import AskKeyCore

/// One import boundary shared by the standalone importer and credential editor.
enum FrozenEnvImport {
    struct Source {
        let text: String
        let pairs: [(name: String, value: String)]
    }

    enum ImportError: LocalizedError {
        case invalidUTF8
        var errorDescription: String? { "The .env file must contain valid UTF-8 text." }
    }

    static func errorMessage(_ error: Error) -> String {
        if let formatError = error as? EnvFileFormatError {
            return String(format: appLocalized("Line %ld: %@"), formatError.lineNumber,
                appLocalized(formatError.localizationKey))
        }
        return appLocalized(error.localizedDescription)
    }

    static func parse(_ text: String) throws -> [(name: String, value: String)] {
        guard text.utf8.count <= FileImport.maxByteCount else {
            throw VaultError.invalidFileCredential(.tooLarge)
        }
        return try EnvFileFormat.parseValidated(text)
    }

    static func load(url: URL) throws -> Source {
        let frozen = try FileImport.freeze(url: url)
        guard let text = String(data: frozen.bytes, encoding: .utf8) else {
            throw ImportError.invalidUTF8
        }
        return Source(text: text, pairs: try parse(text))
    }
}
