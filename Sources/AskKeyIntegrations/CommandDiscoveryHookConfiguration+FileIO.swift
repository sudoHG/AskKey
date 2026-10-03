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
