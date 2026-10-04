import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    func readSnapshot(at url: URL, checkParent: Bool) throws -> Snapshot? {
        if checkParent { try inspectDirectory(url.deletingLastPathComponent(), error: .unsafeHooksFile) }
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else { throw Error.unsafeHooksFile }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw Error.unsafeHooksFile
        }
        if format == .claudeMerged {
            guard info.st_nlink == 1, info.st_mode & 0o022 == 0,
                  info.st_mode & 0o400 != 0 else { throw Error.unsafeHooksFile }
        }
        do {
            let file = try ClientConfigFileIO.readRegularFile(url, maximumBytes: Self.maximumHooksBytes)
            return Snapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw Error.fileTooLarge
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch { throw Error.unsafeHooksFile }
    }
}
