import Darwin
import Foundation

enum BrokerRuntimeDirectory {
    static func prepareStagingDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw BrokerFileWriteError.stagingNotADirectory
            }
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            let permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            guard (permissions?.uint16Value ?? 0) & 0o777 == 0o700 else {
                throw BrokerFileWriteError.stagingPermissionDenied
            }
        } catch let error as BrokerFileWriteError {
            throw error
        } catch {
            throw mappedDirectoryError(error)
        }
    }

    private static func mappedDirectoryError(_ error: Error) -> BrokerFileWriteError {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == EACCES || nsError.code == EPERM {
            return .stagingPermissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError
            || nsError.code == NSFileReadNoPermissionError
            || nsError.code == NSFileWriteVolumeReadOnlyError {
            return .stagingPermissionDenied
        }
        return .stagingFailed
    }
}
