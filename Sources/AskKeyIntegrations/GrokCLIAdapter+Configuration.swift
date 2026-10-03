import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

extension GrokCLIAdapter {
    func grokTOMLDiagnostics(
        _ text: String,
        probe: URL,
        removeProbe: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws -> String {
        let result = probe.path.withCString { mkdir($0, S_IRWXU) }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let diagnostics: Result<String, Error>
        do {
            let config = probe.appendingPathComponent("config.toml")
            try Data(text.utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: config.path
            )
            let output = try runGrok(["mcp", "list", "--json"], grokHomeOverride: probe)
            diagnostics = .success(String(decoding: output.stdout + output.stderr, as: UTF8.self))
        } catch {
            diagnostics = .failure(error)
        }
        do {
            try removeProbe(probe)
        } catch {
            throw GrokCLIAdapterError.diagnosticsCleanupFailed
        }
        return try diagnostics.get()
    }

    func prepareIsolatedHome() throws {
        do {
            try FileManager.default.createDirectory(
                at: isolatedHome,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw GrokCLIAdapterError.unsafeConfig
        }
        var info = stat()
        guard isolatedHome.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              isolatedHome.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func inspectConfigFile() throws {
        do {
            _ = try ClientConfigFileIO.inspectRegularFile(configURL)
        } catch {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func readOriginal() throws -> OriginalConfig {
        do {
            let file = try ClientConfigFileIO.readRegularFile(configURL)
            guard let text = String(data: file.bytes, encoding: .utf8) else {
                throw GrokCLIAdapterError.invalidConfig
            }
            return OriginalConfig(data: file.bytes, text: text, mode: Int16(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return OriginalConfig()
        } catch ClientConfigFileIO.Failure.tooLarge, ClientConfigFileIO.Failure.unsafe {
            throw GrokCLIAdapterError.unsafeConfig
        }
    }

    func validateUserTOML(_ text: String) throws {
        if canUseOfficialGrok() {
            let combined = try grokTOMLDiagnostics(text)
            if combined.localizedCaseInsensitiveContains("syntax errors")
                || combined.localizedCaseInsensitiveContains("TOML parse") {
                throw GrokCLIAdapterError.invalidConfig
            }
        }
        _ = try GrokUserTOML.parse(text)
    }

    func canUseOfficialGrok() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: grokExecutable.path) else { return false }
        guard let help = try? runGrok(["mcp", "add", "--help"]) else { return false }
        if help.status != 0 { return false }
        let output = String(decoding: help.stdout + help.stderr, as: UTF8.self)
        if output.contains("--scope") { return true }
        return false
    }

    private func grokTOMLDiagnostics(_ text: String) throws -> String {
        return try grokTOMLDiagnostics(
            text,
            probe: makeDiagnosticsProbe(),
            removeProbe: removeDiagnosticsProbe
        )
    }

    func atomicWrite(_ data: Data, to url: URL, mode: Int16, exclusive: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try ClientConfigFileIO.publishAtomically(
                data,
                to: url,
                mode: mode_t(mode),
                exclusive: exclusive,
                temporaryPrefix: ".\(url.lastPathComponent).tmp-",
                didCreateTemporary: observeAtomicWriteTemporary
            )
        } catch ClientConfigFileIO.Failure.exclusiveExists {
            throw POSIXError(.EEXIST)
        } catch let error as POSIXError {
            throw error
        } catch {
            throw posixFailure()
        }
    }

}

private func posixFailure() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
