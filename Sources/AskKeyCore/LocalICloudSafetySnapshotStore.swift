import Foundation

public final class LocalICloudSafetySnapshotStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    @discardableResult
    public func persist(_ encryptedSnapshot: Data) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let url = directory.appendingPathComponent("restore-\(UUID().uuidString).snapshot")
        try encryptedSnapshot.write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
        return url
    }
}
