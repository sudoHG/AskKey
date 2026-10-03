import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexUserMCPAdapter {
    func inspectConfigPath() throws {
        try rejectUnsafeNode(configURL, allowMissing: true, requireRegularFile: true)
        try rejectUnsafeNode(configURL.deletingLastPathComponent(), allowMissing: true, requireRegularFile: false)
    }

    func readConfig() throws -> CodexOriginalConfig? {
        try inspectConfigPath()
        guard let data = try readRegularFile(configURL) else { return nil }
        guard data.bytes.count <= Self.maximumConfigBytes else {
            throw CodexUserMCPError.illegalConfig
        }
        guard !data.bytes.contains(0) else { throw CodexUserMCPError.illegalConfig }
        guard let text = String(data: data.bytes, encoding: .utf8) else {
            throw CodexUserMCPError.illegalConfig
        }
        try CodexAskKeyTOML.validate(text)
        return CodexOriginalConfig(text: text, mode: data.mode)
    }

    func atomicWrite(_ data: Data, mode: Int, exclusive: Bool = false) throws {
        try ensureDirectory(configURL.deletingLastPathComponent(), mode: 0o700, excludeFromBackup: false)
        do {
            try ClientConfigFileIO.publishAtomically(
                data,
                to: configURL,
                mode: mode_t(mode),
                exclusive: exclusive,
                temporaryPrefix: ".askkey-"
            )
        } catch {
            throw CodexUserMCPError.connectionFailed("write")
        }
    }

    func renameExclusively(_ source: URL, _ destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw CodexUserMCPError.rollbackFailed
        }
    }
}
private func rejectUnsafeNode(_ url: URL, allowMissing: Bool, requireRegularFile: Bool) throws {
    var st = stat()
    let result = url.path.withCString { lstat($0, &st) }
    if result != 0 {
        if allowMissing, errno == ENOENT { return }
        throw CodexUserMCPError.unsafeConfigFile
    }
    let type = st.st_mode & S_IFMT
    if type == S_IFLNK { throw CodexUserMCPError.unsafeConfigFile }
    if requireRegularFile, type != S_IFREG { throw CodexUserMCPError.unsafeConfigFile }
    if !requireRegularFile, type != S_IFDIR { throw CodexUserMCPError.unsafeConfigFile }
}

func ensureDirectory(_ url: URL, mode: Int, excludeFromBackup: Bool) throws {
    var st = stat()
    if url.path.withCString({ lstat($0, &st) }) == 0 {
        if (st.st_mode & S_IFMT) != S_IFDIR { throw CodexUserMCPError.unsafeConfigFile }
        if excludeFromBackup {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: url.path
            )
            try excludeURLFromBackup(url)
        }
        return
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: mode)],
        ofItemAtPath: url.path
    )
    if excludeFromBackup {
        try excludeURLFromBackup(url)
    }
}

private func excludeURLFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try mutable.setResourceValues(values)
}

func readRegularFile(_ url: URL) throws -> FileBytes? {
    do {
        let file = try ClientConfigFileIO.readRegularFile(
            url,
            maximumBytes: CodexUserMCPAdapter.maximumConfigBytes
        )
        return FileBytes(bytes: file.bytes, mode: Int(file.mode))
    } catch ClientConfigFileIO.Failure.notFound {
        return nil
    } catch ClientConfigFileIO.Failure.tooLarge {
        throw CodexUserMCPError.illegalConfig
    } catch {
        throw CodexUserMCPError.unsafeConfigFile
    }
}
