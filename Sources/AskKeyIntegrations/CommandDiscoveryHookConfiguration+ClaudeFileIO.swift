import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    /// An atomic swap keeps the shared settings file present throughout the
    /// replacement and retains the displaced file for a concurrency check.
    func replaceClaude(current: Snapshot, replacement: Data, mode: UInt32) throws {
        let temporary: URL
        do {
            temporary = try ClientConfigFileIO.writeExclusiveTemporary(
                replacement, in: hooksURL.deletingLastPathComponent(), prefix: ".askkey-claude-"
            )
        } catch { throw Error.writeFailed }
        var removeTemporary = true
        defer { if removeTemporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        } catch { throw Error.writeFailed }
        guard try readSnapshot(at: hooksURL, checkParent: true) == current else { throw Error.concurrentModification }
        try swapClaude(temporary)
        do {
            guard try readSnapshot(at: temporary, checkParent: true) == current else {
                throw Error.concurrentModification
            }
        } catch {
            // Restore the displaced writer's file only while our published
            // replacement still occupies the destination. Preserve both
            // files for recovery if another writer has already intervened.
            let published: Snapshot?
            do { published = try readSnapshot(at: hooksURL, checkParent: true) }
            catch { removeTemporary = false; throw Error.rollbackFailed }
            guard let published,
                  published.bytes == replacement, published.mode == mode else {
                removeTemporary = false
                throw Error.rollbackFailed
            }
            do { try swapClaude(temporary) }
            catch { removeTemporary = false; throw Error.rollbackFailed }
            throw error
        }
    }

    private func swapClaude(_ temporary: URL) throws {
        let result = temporary.path.withCString { source in
            hooksURL.path.withCString { destination in
                renamex_np(source, destination, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw Error.concurrentModification }
    }
}
