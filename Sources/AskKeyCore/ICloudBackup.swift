import CryptoKit
import Darwin
import Foundation
import Security

public enum ICloudBackupStoreError: Error, Equatable {
    case alreadyExists
    case unavailable
}

public protocol ICloudBackupStore: AnyObject {
    func create(_ data: Data, at path: String) throws
    func replace(_ data: Data, at path: String) throws
    func read(at path: String) throws -> Data?
    /// Lists files beneath a directory prefix; a single trailing slash is optional.
    /// File operations still require a complete, non-directory relative path.
    func list(prefix: String) throws -> [String]
    func conflictPaths(prefix: String) throws -> [String]
    func resolveConflicts(prefix: String) throws
    func delete(at path: String) throws
}

public protocol ICloudBackupContainerProviding {
    func containerURL() -> URL?
}

public struct SystemICloudBackupContainerProvider: ICloudBackupContainerProviding {
    private let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: identifier)
    }
}

public final class ICloudFileBackupStore: ICloudBackupStore {
    private let root: URL
    private let fileManager: FileManager

#if DEBUG
    enum ExclusiveWritePoint { case partialWrite, beforePublication }
    // In-process test seam only; production never reads crash-control environment.
    var exclusiveWriteProbe: ((ExclusiveWritePoint, URL) -> Void)?
#endif

    public init(
        provider: ICloudBackupContainerProviding,
        fileManager: FileManager = .default
    ) throws {
        guard let container = provider.containerURL() else {
            throw ICloudBackupError.containerUnavailable
        }
        self.fileManager = fileManager
        root = container.appendingPathComponent("Documents", isDirectory: true)
    }

    public func create(_ data: Data, at path: String) throws {
        let url = try fileURL(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withLocallyStaged(data) { verified in
            try writeExclusive(verified, to: url)
        }
    }

    public func replace(_ data: Data, at path: String) throws {
        let url = try fileURL(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try withLocallyStaged(data) { verified in
            try verified.write(to: url, options: .atomic)
        }
    }

    public func read(at path: String) throws -> Data? {
        let url = try fileURL(path)
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    public func list(prefix: String) throws -> [String] {
        let directoryPath = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        let prefixURL = try fileURL(directoryPath)
        var result: [String] = []
        var directories = [prefixURL]
        while let directory = directories.popLast() {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                if directory == prefixURL { return [] }
                throw error
            }
            for url in children {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    directories.append(url)
                } else if values.isRegularFile == true {
                    let rootPath = root.standardizedFileURL.path
                    let filePath = url.standardizedFileURL.path
                    guard filePath.hasPrefix(rootPath + "/") else {
                        throw ICloudBackupStoreError.unavailable
                    }
                    let relative = String(filePath.dropFirst(rootPath.count + 1))
                    result.append(relative)
                }
            }
        }
        return result.sorted()
    }

    public func conflictPaths(prefix: String) throws -> [String] {
        try list(prefix: prefix).filter { path in
            let url = root.appendingPathComponent(path)
            return path.localizedCaseInsensitiveContains("conflicted copy")
                || !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty
        }
    }

    public func resolveConflicts(prefix: String) throws {
        for path in try conflictPaths(prefix: prefix) {
            if path.localizedCaseInsensitiveContains("conflicted copy") {
                try delete(at: path)
                continue
            }
            let url = try fileURL(path)
            for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
                version.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
    }

    public func delete(at path: String) throws {
        do {
            try fileManager.removeItem(at: fileURL(path))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private func fileURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.first == "askkey-backup",
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ICloudBackupStoreError.unavailable
        }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    private func withLocallyStaged(_ data: Data, upload: (Data) throws -> Void) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AskKeyBackupStage-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            let file = directory.appendingPathComponent("payload")
            try data.write(to: file, options: .atomic)
            let verified = try Data(contentsOf: file, options: .mappedIfSafe)
            guard verified == data else { throw ICloudBackupStoreError.unavailable }
            try upload(verified)
            try fileManager.removeItem(at: directory)
        } catch {
            let primary = error
            do {
                try fileManager.removeItem(at: directory)
            } catch let cleanup as CocoaError where cleanup.code == .fileNoSuchFile {
                throw primary
            } catch {
                throw ICloudBackupError.cleanupFailed(
                    primary: String(describing: primary),
                    cleanup: String(describing: error)
                )
            }
            throw primary
        }
    }

    private func writeExclusive(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let directoryFD = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directoryFD) }
        let temporaryName = ".askkey-upload-\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var descriptorOpen = true
        defer { if descriptorOpen { Darwin.close(descriptor) } }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    guard let base = bytes.baseAddress else { throw POSIXError(.EIO) }
                    var count = min(65_536, bytes.count - offset)
#if DEBUG
                    if offset == 0, exclusiveWriteProbe != nil { count = max(1, min(count, bytes.count / 2)) }
#endif
                    let written = Darwin.write(descriptor, base.advanced(by: offset), count)
                    if written > 0 {
                        offset += written
#if DEBUG
                        if offset < bytes.count { exclusiveWriteProbe?(.partialWrite, url) }
#endif
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let closed = Darwin.close(descriptor)
            descriptorOpen = false
            guard closed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
#if DEBUG
            exclusiveWriteProbe?(.beforePublication, url)
#endif
            // Publish only complete, synced bytes. RENAME_EXCL atomically rejects
            // another writer's final object; a killed writer leaves only a hidden
            // temporary file, excluded from list()/generation discovery.
            let published = temporaryName.withCString { source in
                url.lastPathComponent.withCString { destination in
                    renameatx_np(directoryFD, source, directoryFD, destination, UInt32(RENAME_EXCL))
                }
            }
            guard published == 0 else {
                if errno == EEXIST { throw ICloudBackupStoreError.alreadyExists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fsync(directoryFD) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // createDirectory may have introduced several ancestors. Persist each
            // link through Documents' parent before reporting a successful write.
            var ancestor = directory.deletingLastPathComponent()
            let boundary = root.deletingLastPathComponent().standardizedFileURL
            while ancestor.standardizedFileURL.path.hasPrefix(boundary.path + "/") || ancestor.standardizedFileURL == boundary {
                let fd = ancestor.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let result = fsync(fd)
                let failureCode = errno
                Darwin.close(fd)
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: failureCode) ?? .EIO) }
                if ancestor.standardizedFileURL == boundary { break }
                ancestor.deleteLastPathComponent()
            }
        } catch {
            let primary = error
            // Never unlink the final name: publication may already have succeeded.
            // Journal replay can verify a complete final object after an fsync error.
            let removed = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            guard removed == 0 || errno == ENOENT else {
                throw ICloudBackupError.cleanupFailed(primary: String(describing: primary), cleanup: "Cannot remove unpublished backup temporary file")
            }
            throw primary
        }
    }

}

public struct BackupRecoveryKey: Codable, Equatable, Sendable {
    public let encoded: String
    fileprivate let bytes: Data

    public init(encoded: String) throws {
        guard let bytes = Data(base64Encoded: encoded), bytes.count == 32 else {
            throw ICloudBackupError.invalidRecoveryKey
        }
        self.encoded = encoded
        self.bytes = bytes
    }

    public var keyID: String {
        Self.hex(Data(SHA256.hash(data: bytes)).prefix(16))
    }

    public static func generate() throws -> BackupRecoveryKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ICloudBackupError.randomGenerationFailed(status) }
        return try BackupRecoveryKey(encoded: Data(bytes).base64EncodedString())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(encoded: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }

    private static func hex<T: DataProtocol>(_ data: T) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public struct ICloudBackupGeneration: Equatable, Sendable {
    public let id: String
    public let createdAt: Date

    public init(id: String, createdAt: Date) {
        self.id = id
        self.createdAt = createdAt
    }
}

public struct ICloudBackupRestoreSelection: Equatable, Sendable {
    public let generation: ICloudBackupGeneration
    public let snapshot: ICloudBackupSnapshot
}

public enum ICloudBackupError: Error, Equatable {
    case invalidRecoveryKey
    case randomGenerationFailed(OSStatus)
    case noValidGeneration
    case invalidGeneration(String)
    case automaticBackupPaused
    case conflictCopy
    case differentWriter
    case forkDetected
    case propagationPending
    case containerUnavailable
    case capabilityUnavailable
    case invalidSnapshot
    case authenticationRequired
    case keyMaterialReadFailed(OSStatus)
    case keyMaterialWriteFailed(OSStatus)
    case cleanupFailed(primary: String, cleanup: String)
    case invalidCleanupState
    case invalidPendingUpload
}

extension ICloudBackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecoveryKey: return "恢复密钥无效，请检查后重试。"
        case .randomGenerationFailed: return "无法安全生成恢复密钥，请稍后重试。"
        case .noValidGeneration: return "没有找到完整且可验证的备份。"
        case .invalidGeneration: return "备份内容不完整或已损坏。"
        case .automaticBackupPaused: return "自动备份已暂停，请先处理备份冲突。"
        case .conflictCopy, .forkDetected: return "发现多个备份版本，请选择要恢复的版本。"
        case .differentWriter: return "这份备份由另一台设备写入，请先确认接管。"
        case .propagationPending: return "iCloud 仍在同步，请稍后重试。"
        case .containerUnavailable: return "iCloud 备份当前不可用，请检查 iCloud 后重试。"
        case .capabilityUnavailable: return "此开发或临时签名版本没有请旨自有 iCloud 能力。正式发布需要注入自有容器、entitlement 与签名材料。"
        case .invalidSnapshot: return "备份内容无法安全恢复。"
        case .authenticationRequired: return "需要先通过系统验证。"
        case .keyMaterialReadFailed: return "无法读取本机备份密钥，请检查钥匙串访问。"
        case .keyMaterialWriteFailed: return "无法保存本机备份密钥，请检查钥匙串访问。"
        case .cleanupFailed: return "备份操作未能完整收尾，请稍后重试；现有备份仍被保留。"
        case .invalidCleanupState: return "备份清理状态异常，已安全停止。"
        case .invalidPendingUpload: return "本机待完成备份无法验证，已停止继续写入。"
        }
    }
}

public final class ICloudBackupCoordinator {
    public static let formatVersion = 1

    private struct Manifest: Codable {
        let formatVersion: Int
        let generationID: String
        let keyID: String
        let writerID: String
        let parentGenerationID: String?
        let createdAt: String
        let nonce: String
        let ciphertextDigest: String
    }

    private struct Hint: Codable {
        let generationID: String
    }

    private struct WriterMarker: Codable {
        let writerID: String
    }

    private struct ChildClaim: Codable {
        let generationID: String
    }

    private struct ValidatedGeneration {
        let manifest: Manifest
        let payload: Data
        let createdAt: Date
    }

    /// Persisted locally before claiming cloud ownership. A writer-only intent
    /// also covers termination between writer.json and generation preparation.
    /// Abort paths are recorded before cleanup, so restart never resurrects a
    /// generation whose deletion had already begun.
    private struct PendingUpload: Codable {
        let initialWriterClaim: Bool
        let manifest: Manifest?
        let blob: Data?
        var abortPaths: [String]?
    }

    private let store: ICloudBackupStore
    private let recoveryKey: BackupRecoveryKey
    private let writerID: String
    private let keyID: String
    private let root: String
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let stateStore: ICloudBackupLocalStateStore
    private let lock = NSLock()
    private var paused = false
    private var pendingCleanup: [String] = []

    public init(
        store: ICloudBackupStore,
        recoveryKey: BackupRecoveryKey,
        writerID: String,
        stateStore: ICloudBackupLocalStateStore
    ) throws {
        guard let writerUUID = UUID(uuidString: writerID) else {
            throw ICloudBackupError.invalidGeneration("writer ID")
        }
        self.store = store
        self.recoveryKey = recoveryKey
        self.writerID = writerUUID.uuidString.lowercased()
        self.stateStore = stateStore
        keyID = recoveryKey.keyID
        root = "askkey-backup/\(keyID)"
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        paused = try stateStore.isAutomaticBackupPaused(namespace: keyID)
        let recordedCleanup = try stateStore.pendingCleanupPaths(namespace: keyID)
        pendingCleanup = try validatedCleanupPaths(recordedCleanup)
        if pendingCleanup != recordedCleanup {
            try stateStore.setPendingCleanupPaths(pendingCleanup, namespace: keyID)
        }
    }

    public convenience init(
        store: ICloudBackupStore,
        material: ICloudBackupKeyMaterial,
        stateStore: ICloudBackupLocalStateStore
    ) throws {
        try self.init(
            store: store,
            recoveryKey: material.recoveryKey,
            writerID: material.writerID,
            stateStore: stateStore
        )
    }

    public func automaticBackupIsPaused() throws -> Bool {
        try lock.withLock {
            stateStore.beginExclusiveAccess(namespace: keyID)
            defer { stateStore.endExclusiveAccess(namespace: keyID) }
            if paused { return true }
            let persisted = try stateStore.isAutomaticBackupPaused(namespace: keyID)
            if persisted { paused = true }
            return persisted
        }
    }

    public func backUp(
        snapshot: ICloudBackupSnapshot,
        createdAt: Date = Date()
    ) throws -> ICloudBackupGeneration {
        guard snapshot.formatVersion == ICloudBackupSnapshot.formatVersion else {
            throw ICloudBackupError.invalidSnapshot
        }
        do {
            try snapshot.credentials.forEach(CredentialFieldValidation.backupCredential)
        } catch {
            throw ICloudBackupError.invalidSnapshot
        }
        return try backUp(payload: encoder.encode(snapshot), createdAt: createdAt)
    }

    private func backUp(payload: Data, createdAt: Date) throws -> ICloudBackupGeneration {
        try lock.withLock {
            stateStore.beginExclusiveAccess(namespace: keyID)
            defer { stateStore.endExclusiveAccess(namespace: keyID) }
            if paused {
                throw ICloudBackupError.automaticBackupPaused
            }
            if try stateStore.isAutomaticBackupPaused(namespace: keyID) {
                paused = true
                throw ICloudBackupError.automaticBackupPaused
            }
            if !pendingCleanup.isEmpty {
                try cleanOwnedPaths(
                    pendingCleanup,
                    primary: ICloudBackupError.invalidGeneration("pending cleanup")
                )
            }
            guard try store.conflictPaths(prefix: root).isEmpty else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.conflictCopy
            }

            var pending = try readPendingUpload()
            if let abortPaths = pending?.abortPaths {
                try cleanOwnedPaths(abortPaths, primary: ICloudBackupError.invalidPendingUpload)
                try stateStore.setPendingUpload(nil, namespace: keyID)
                pending = nil
            }
            if let pending, pending.manifest != nil {
                return try finishPendingUpload(pending)
            }
            // Record the fact that this device is about to establish the first
            // writer before publishing that fact to iCloud.
            if pending == nil, try store.read(at: "\(root)/writer.json") == nil {
                let intent = PendingUpload(initialWriterClaim: true, manifest: nil, blob: nil)
                try savePendingUpload(intent)
                pending = intent
            }
            let writerWasCreated = try claimWriter()
            if let committed = try reconcileCommittedGenerations(
                writerWasCreated: writerWasCreated || pending?.initialWriterClaim == true
            ) {
                try stateStore.setPendingUpload(nil, namespace: keyID)
                return committed
            }
            let parent = try readHint(named: "current")
            let generationID = UUID().uuidString.lowercased()
            let createdAtString = Self.timestamp(createdAt)
            let key = encryptionKey()
            let authenticatedFields = Self.authenticatedFields(
                formatVersion: Self.formatVersion,
                generationID: generationID,
                keyID: keyID,
                writerID: writerID,
                parentGenerationID: parent,
                createdAt: createdAtString
            )
            let sealed = try AES.GCM.seal(payload, using: key, authenticating: authenticatedFields)
            guard let blob = sealed.combined else {
                throw ICloudBackupError.invalidGeneration(generationID)
            }
            let manifest = Manifest(
                formatVersion: Self.formatVersion,
                generationID: generationID,
                keyID: keyID,
                writerID: writerID,
                parentGenerationID: parent,
                createdAt: createdAtString,
                nonce: Data(sealed.nonce).base64EncodedString(),
                ciphertextDigest: Self.hex(Data(SHA256.hash(data: blob)))
            )

            let prepared = PendingUpload(
                initialWriterClaim: pending?.initialWriterClaim ?? writerWasCreated,
                manifest: manifest,
                blob: blob
            )
            try savePendingUpload(prepared)

            let claimPath = childClaimPath(parent)
            do {
                try store.create(
                    try encoder.encode(ChildClaim(generationID: generationID)),
                    at: claimPath
                )
            } catch ICloudBackupStoreError.alreadyExists {
                try abortPendingUpload(
                    prepared,
                    ownedPaths: prepared.initialWriterClaim ? ["\(root)/writer.json"] : [],
                    primary: ICloudBackupError.propagationPending
                )
                throw ICloudBackupError.propagationPending
            } catch {
                let primary = error
                var owned = prepared.initialWriterClaim ? ["\(root)/writer.json"] : []
                if try readChildClaim(parent: parent) == generationID { owned.append(claimPath) }
                try abortPendingUpload(prepared, ownedPaths: owned, primary: primary)
                throw primary
            }
            var blobCreated = false
            do {
                try store.create(blob, at: blobPath(generationID))
                blobCreated = true
                try store.create(try encoder.encode(manifest), at: manifestPath(generationID))
            } catch {
                let primary = error
                var owned = [claimPath]
                if blobCreated { owned.append(blobPath(generationID)) }
                if prepared.initialWriterClaim { owned.append("\(root)/writer.json") }
                // A staging-cleanup failure may be reported after both cloud
                // objects committed. Keep the durable upload for finalization.
                if (try? validatedGeneration(generationID).payload) != payload {
                    try abortPendingUpload(prepared, ownedPaths: owned, primary: primary)
                }
                throw primary
            }
            do {
                guard try validatedGeneration(generationID).payload == payload else {
                    throw ICloudBackupError.invalidGeneration(generationID)
                }
            } catch ICloudBackupError.invalidGeneration(let invalidID) {
                let manifestVisible = try store.read(at: manifestPath(generationID)) != nil
                let blobVisible = try store.read(at: blobPath(generationID)) != nil
                guard manifestVisible, blobVisible else {
                    // The immutable upload may still be propagating. Never
                    // advance a hint until both objects can be authenticated.
                    throw ICloudBackupError.propagationPending
                }
                let primary = ICloudBackupError.invalidGeneration(invalidID)
                var owned = [manifestPath(generationID), blobPath(generationID), claimPath]
                if prepared.initialWriterClaim { owned.append("\(root)/writer.json") }
                try abortPendingUpload(prepared, ownedPaths: owned, primary: primary)
                throw primary
            }
            if let parent {
                try store.replace(try encoder.encode(Hint(generationID: parent)), at: hintPath("previous"))
            }
            try store.replace(try encoder.encode(Hint(generationID: generationID)), at: hintPath("current"))
            try pruneGenerations(current: generationID, previous: parent)
            try stateStore.setPendingUpload(nil, namespace: keyID)
            return ICloudBackupGeneration(id: generationID, createdAt: createdAt)
        }
    }

    private func savePendingUpload(_ pending: PendingUpload) throws {
        let sealed = try AES.GCM.seal(
            encoder.encode(pending), using: pendingUploadKey(),
            authenticating: Data("\(keyID)\n\(writerID)".utf8)
        )
        guard let data = sealed.combined else { throw ICloudBackupError.invalidPendingUpload }
        try stateStore.setPendingUpload(data, namespace: keyID)
    }

    private func readPendingUpload() throws -> PendingUpload? {
        guard let data = try stateStore.pendingUpload(namespace: keyID) else { return nil }
        do {
            let decoded = try AES.GCM.open(
                AES.GCM.SealedBox(combined: data), using: pendingUploadKey(),
                authenticating: Data("\(keyID)\n\(writerID)".utf8)
            )
            let pending = try decoder.decode(PendingUpload.self, from: decoded)
            switch (pending.manifest, pending.blob) {
            case let (.some(manifest), .some(blob)):
                let validated = try validateGeneration(
                    manifest.generationID, manifestData: encoder.encode(manifest), blob: blob
                )
                guard validated.manifest.writerID == writerID else {
                    throw ICloudBackupError.invalidPendingUpload
                }
            case (.none, .none):
                guard pending.initialWriterClaim, pending.abortPaths == nil else {
                    throw ICloudBackupError.invalidPendingUpload
                }
            default: throw ICloudBackupError.invalidPendingUpload
            }
            return pending
        } catch {
            throw ICloudBackupError.invalidPendingUpload
        }
    }

    private func pendingUploadKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey.bytes),
            salt: Data(keyID.utf8), info: Data("Ask Key pending backup upload v1".utf8),
            outputByteCount: 32
        )
    }

    private func abortPendingUpload(
        _ pending: PendingUpload,
        ownedPaths: [String],
        primary: Error
    ) throws {
        var aborting = pending
        aborting.abortPaths = Array(Set(ownedPaths)).sorted()
        do {
            try savePendingUpload(aborting)
            try cleanOwnedPaths(ownedPaths, primary: primary)
            try stateStore.setPendingUpload(nil, namespace: keyID)
        } catch let error as ICloudBackupError {
            if case .cleanupFailed = error { throw error }
            throw ICloudBackupError.cleanupFailed(
                primary: String(describing: primary), cleanup: String(describing: error)
            )
        } catch {
            throw ICloudBackupError.cleanupFailed(
                primary: String(describing: primary), cleanup: String(describing: error)
            )
        }
    }

    /// Replays exactly the authenticated local generation. Unknown cloud claims
    /// and immutable objects are never replaced or guessed to be stale.
    private func finishPendingUpload(_ pending: PendingUpload) throws -> ICloudBackupGeneration {
        guard let manifest = pending.manifest, let blob = pending.blob else {
            throw ICloudBackupError.invalidPendingUpload
        }
        _ = try claimWriter()
        let current = try readHint(named: "current")
        guard current == manifest.parentGenerationID || current == manifest.generationID else {
            throw ICloudBackupError.propagationPending
        }
        if let parent = manifest.parentGenerationID {
            let generation = try validatedGeneration(parent)
            guard try writerIsAccepted(for: generation) else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
        }
        // A local preparation proves which upload we own; it does not grant
        // permission to choose a branch if another valid child has appeared.
        for path in try store.list(prefix: "\(root)/generations/")
            where path.hasSuffix("/manifest.json") {
            guard let id = path.split(separator: "/").dropLast().last,
                  let candidate = try? validatedGeneration(String(id)),
                  candidate.manifest.parentGenerationID == manifest.parentGenerationID,
                  candidate.manifest.generationID != manifest.generationID else { continue }
            try pauseAutomaticBackup()
            throw ICloudBackupError.forkDetected
        }
        let claimData = try encoder.encode(ChildClaim(generationID: manifest.generationID))
        try createOrVerifyImmutable(claimData, at: childClaimPath(manifest.parentGenerationID))
        try createOrVerifyImmutable(blob, at: blobPath(manifest.generationID))
        try createOrVerifyImmutable(encoder.encode(manifest), at: manifestPath(manifest.generationID))
        let validated: ValidatedGeneration
        do {
            validated = try validatedGeneration(manifest.generationID)
        } catch ICloudBackupError.invalidGeneration {
            throw ICloudBackupError.propagationPending
        }
        if let parent = manifest.parentGenerationID {
            try store.replace(try encoder.encode(Hint(generationID: parent)), at: hintPath("previous"))
        }
        try store.replace(
            try encoder.encode(Hint(generationID: manifest.generationID)), at: hintPath("current")
        )
        try pruneGenerations(current: manifest.generationID, previous: manifest.parentGenerationID)
        try stateStore.setPendingUpload(nil, namespace: keyID)
        return generation(from: validated)
    }

    private func createOrVerifyImmutable(_ data: Data, at path: String) throws {
        if let existing = try store.read(at: path) {
            guard existing == data else { throw ICloudBackupError.invalidPendingUpload }
            return
        }
        do {
            try store.create(data, at: path)
        } catch ICloudBackupStoreError.alreadyExists {
            guard try store.read(at: path) == data else {
                throw ICloudBackupError.invalidPendingUpload
            }
        }
    }

    public func restore() throws -> ICloudBackupSnapshot {
        try restoreSelection().snapshot
    }

    public func restoreSelection() throws -> ICloudBackupRestoreSelection {
        try restoreSelection(generationID: nil)
    }

    public func recoverableGenerations() throws -> [ICloudBackupGeneration] {
        try lock.withLock {
            stateStore.beginExclusiveAccess(namespace: keyID)
            defer { stateStore.endExclusiveAccess(namespace: keyID) }
            let candidates = try restoreCandidates(allowConflicts: true)
            var writerConflictDetected = candidates.writerConflictDetected
            for leaf in candidates.leaves where try writerIsAccepted(for: leaf) == false {
                writerConflictDetected = true
            }
            if candidates.leaves.count > 1 || writerConflictDetected {
                try pauseAutomaticBackup()
            }
            return candidates.generations
                .map(generation(from:))
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func restoreSelection(
        generationID: String?
    ) throws -> ICloudBackupRestoreSelection {
        let leaf = try restoreLeaf(generationID: generationID)
        let snapshot: ICloudBackupSnapshot
        do {
            snapshot = try decoder.decode(ICloudBackupSnapshot.self, from: leaf.payload)
        } catch {
            throw ICloudBackupError.invalidSnapshot
        }
        guard snapshot.hasSupportedFormatVersion else {
            throw ICloudBackupError.invalidSnapshot
        }
        return ICloudBackupRestoreSelection(
            generation: generation(from: leaf),
            snapshot: snapshot
        )
    }

    public func restore(
        into target: ICloudBackupRestoreTarget,
        using authenticator: ManagementAuthenticator,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws {
        _ = try restoreSelectedGeneration(
            into: target,
            using: authenticator,
            persistLocalSafetySnapshot: persistLocalSafetySnapshot
        )
    }

    @discardableResult
    public func restoreSelectedGeneration(
        into target: ICloudBackupRestoreTarget,
        using authenticator: ManagementAuthenticator,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws -> ICloudBackupGeneration {
        guard authenticator.confirm(reason: "Restore Ask Key encrypted backup") else {
            throw ICloudBackupError.authenticationRequired
        }
        let selection = try restoreSelection()
        try target.restoreLibraryAtomically(
            with: selection.snapshot.requiringApprovalAfterRestore(),
            persistLocalSafetySnapshot: persistLocalSafetySnapshot
        )
        return selection.generation
    }

    @discardableResult
    public func restoreGeneration(
        _ generationID: String,
        into target: ICloudBackupRestoreTarget,
        using authenticator: ManagementAuthenticator,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws -> ICloudBackupGeneration {
        guard authenticator.confirm(reason: "Restore Ask Key encrypted backup") else {
            throw ICloudBackupError.authenticationRequired
        }
        let selection = try restoreSelection(generationID: generationID)
        try target.restoreLibraryAtomically(
            with: selection.snapshot.requiringApprovalAfterRestore(),
            persistLocalSafetySnapshot: persistLocalSafetySnapshot
        )
        return selection.generation
    }

    public func resumeAfterUserTakesOwnership(of generationID: String) throws {
        try lock.withLock {
            stateStore.beginExclusiveAccess(namespace: keyID)
            defer { stateStore.endExclusiveAccess(namespace: keyID) }
            let selected = try validatedGeneration(generationID)
            if let parent = selected.manifest.parentGenerationID {
                _ = try validatedGeneration(parent)
            }
            try store.delete(at: childClaimPath(generationID))
            try store.replace(
                try encoder.encode(WriterMarker(writerID: writerID)),
                at: "\(root)/writer.json"
            )
            if let parent = selected.manifest.parentGenerationID {
                try store.replace(try encoder.encode(Hint(generationID: parent)), at: hintPath("previous"))
            } else {
                try store.delete(at: hintPath("previous"))
            }
            try store.replace(try encoder.encode(Hint(generationID: generationID)), at: hintPath("current"))
            try stateStore.setAcceptedTakeoverGeneration(generationID, namespace: keyID)
            try stateStore.setPendingUpload(nil, namespace: keyID)
            try stateStore.setAutomaticBackupPaused(false, namespace: keyID)
            do {
                try store.resolveConflicts(prefix: root)
            } catch {
                let resolutionError = error
                do {
                    try stateStore.setAutomaticBackupPaused(true, namespace: keyID)
                } catch {
                    paused = true
                    throw ICloudBackupError.cleanupFailed(
                        primary: String(describing: resolutionError),
                        cleanup: String(describing: error)
                    )
                }
                paused = true
                throw resolutionError
            }
            paused = false
        }
    }

    private func restoreLeaf(generationID: String?) throws -> ValidatedGeneration {
        try lock.withLock {
            stateStore.beginExclusiveAccess(namespace: keyID)
            defer { stateStore.endExclusiveAccess(namespace: keyID) }
            let candidates = try restoreCandidates(allowConflicts: generationID != nil)
            let leaf: ValidatedGeneration
            if let generationID {
                guard let selected = candidates.generations.first(where: {
                    $0.manifest.generationID == generationID
                }) else {
                    throw ICloudBackupError.invalidGeneration(generationID)
                }
                leaf = selected
            } else if candidates.leaves.count == 1, let selected = candidates.leaves.first {
                leaf = selected
            } else if let accepted = try stateStore.acceptedTakeoverGeneration(namespace: keyID),
                      let selected = candidates.leaves.first(where: {
                          $0.manifest.generationID == accepted
                      }) {
                leaf = selected
            } else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.forkDetected
            }
            if try writerIsAccepted(for: leaf) == false {
                try pauseAutomaticBackup()
            }
            if candidates.writerConflictDetected || candidates.leaves.count > 1 {
                try pauseAutomaticBackup()
            }
            return leaf
        }
    }

    public func unresolvedConflictPaths() throws -> [String] {
        try store.conflictPaths(prefix: root)
    }

    private func restoreCandidates(allowConflicts: Bool = false) throws -> (
        leaves: [ValidatedGeneration],
        generations: [ValidatedGeneration],
        writerConflictDetected: Bool
    ) {
        let conflicts = try store.conflictPaths(prefix: root)
        if !conflicts.isEmpty {
            try pauseAutomaticBackup()
            if !allowConflicts { throw ICloudBackupError.conflictCopy }
        }
        var writerConflictDetected = false
        if let markerData = try store.read(at: "\(root)/writer.json") {
            do {
                writerConflictDetected = try decoder.decode(WriterMarker.self, from: markerData)
                    .writerID != writerID
            } catch {
                writerConflictDetected = true
            }
        }
        var validByID: [String: ValidatedGeneration] = [:]
        for name in ["current", "previous"] {
            do {
                guard let candidate = try readHint(named: name) else { continue }
                validByID[candidate] = try validatedGeneration(candidate)
            } catch ICloudBackupError.invalidGeneration {
                continue
            }
        }
        for path in try store.list(prefix: "\(root)/generations/")
            where path.hasSuffix("/manifest.json") {
            let components = path.split(separator: "/")
            guard let generationComponent = components.dropLast().last else { continue }
            let generationID = String(generationComponent)
            do {
                validByID[generationID] = try validatedGeneration(generationID)
            } catch ICloudBackupError.invalidGeneration {
                continue
            }
        }
        let parents = Set(validByID.values.compactMap(\.manifest.parentGenerationID))
        let leaves = validByID.values.filter { !parents.contains($0.manifest.generationID) }
        guard !leaves.isEmpty else { throw ICloudBackupError.noValidGeneration }
        return (leaves, Array(validByID.values), writerConflictDetected)
    }

    private func validatedGeneration(_ generationID: String) throws -> ValidatedGeneration {
        guard Self.validIdentifier(generationID),
              let manifestData = try store.read(at: manifestPath(generationID)),
              let blob = try store.read(at: blobPath(generationID)) else {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        return try validateGeneration(generationID, manifestData: manifestData, blob: blob)
    }

    private func validateGeneration(
        _ generationID: String,
        manifestData: Data,
        blob: Data
    ) throws -> ValidatedGeneration {
        let manifest: Manifest
        do {
            manifest = try decoder.decode(Manifest.self, from: manifestData)
        } catch {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        guard let parsedDate = ISO8601DateFormatter().date(from: manifest.createdAt) else {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        guard Self.validIdentifier(generationID),
              manifest.formatVersion == Self.formatVersion,
              manifest.generationID == generationID,
              manifest.keyID == keyID,
              UUID(uuidString: manifest.writerID) != nil,
              manifest.parentGenerationID.map(Self.validIdentifier) ?? true,
              Data(base64Encoded: manifest.nonce)?.count == 12,
              manifest.ciphertextDigest == Self.hex(Data(SHA256.hash(data: blob))) else {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        let authenticatedFields = Self.authenticatedFields(
            formatVersion: manifest.formatVersion,
            generationID: manifest.generationID,
            keyID: manifest.keyID,
            writerID: manifest.writerID,
            parentGenerationID: manifest.parentGenerationID,
            createdAt: manifest.createdAt
        )
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(combined: blob)
        } catch {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        guard Data(sealed.nonce).base64EncodedString() == manifest.nonce else {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        let payload: Data
        do {
            payload = try AES.GCM.open(sealed, using: encryptionKey(), authenticating: authenticatedFields)
        } catch {
            throw ICloudBackupError.invalidGeneration(generationID)
        }
        return ValidatedGeneration(manifest: manifest, payload: payload, createdAt: parsedDate)
    }

    private func reconcileCommittedGenerations(writerWasCreated: Bool) throws -> ICloudBackupGeneration? {
        let manifestPaths = try store.list(prefix: "\(root)/generations/")
            .filter { $0.hasSuffix("/manifest.json") }
        var generations: [ValidatedGeneration] = []
        for path in manifestPaths {
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            do {
                generations.append(try validatedGeneration(String(parts[parts.count - 2])))
            } catch ICloudBackupError.invalidGeneration {
                continue
            }
        }

        let forks = Dictionary(grouping: generations) { $0.manifest.parentGenerationID ?? "<root>" }
        let acceptedTakeover = try stateStore.acceptedTakeoverGeneration(namespace: keyID)
        guard forks.values.allSatisfy({ branch in
            branch.count <= 1 || branch.contains(where: { $0.manifest.generationID == acceptedTakeover })
        }) else {
            try pauseAutomaticBackup()
            throw ICloudBackupError.forkDetected
        }

        let currentID: String?
        do {
            currentID = try readHint(named: "current")
        } catch ICloudBackupError.invalidGeneration {
            throw ICloudBackupError.propagationPending
        }

        guard let currentID else {
            if let claimed = try readChildClaim(parent: nil) {
                let committed: ValidatedGeneration
                do {
                    committed = try validatedGeneration(claimed)
                } catch ICloudBackupError.invalidGeneration {
                    throw ICloudBackupError.propagationPending
                }
                guard try writerIsAccepted(for: committed) else {
                    try pauseAutomaticBackup()
                    throw ICloudBackupError.differentWriter
                }
                try store.replace(
                    try encoder.encode(Hint(generationID: committed.manifest.generationID)),
                    at: hintPath("current")
                )
                try pruneGenerations(current: committed.manifest.generationID, previous: nil)
                return generation(from: committed)
            }
            let roots = generations.filter { $0.manifest.parentGenerationID == nil }
            guard roots.count <= 1 else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.forkDetected
            }
            guard let committed = roots.first else {
                if writerWasCreated { return nil }
                throw ICloudBackupError.propagationPending
            }
            guard try writerIsAccepted(for: committed) else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
            try store.replace(
                try encoder.encode(Hint(generationID: committed.manifest.generationID)),
                at: hintPath("current")
            )
            try pruneGenerations(current: committed.manifest.generationID, previous: nil)
            return generation(from: committed)
        }

        let current: ValidatedGeneration
        do {
            current = try validatedGeneration(currentID)
        } catch ICloudBackupError.invalidGeneration {
            throw ICloudBackupError.propagationPending
        }
        guard manifestPaths.contains(manifestPath(currentID)) else {
            throw ICloudBackupError.propagationPending
        }
        if let claimed = try readChildClaim(parent: currentID) {
            let committed: ValidatedGeneration
            do {
                committed = try validatedGeneration(claimed)
            } catch ICloudBackupError.invalidGeneration {
                throw ICloudBackupError.propagationPending
            }
            guard committed.manifest.parentGenerationID == currentID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.forkDetected
            }
            guard committed.manifest.writerID == writerID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
            try store.replace(try encoder.encode(Hint(generationID: currentID)), at: hintPath("previous"))
            try store.replace(
                try encoder.encode(Hint(generationID: committed.manifest.generationID)),
                at: hintPath("current")
            )
            try pruneGenerations(current: committed.manifest.generationID, previous: currentID)
            return generation(from: committed)
        }
        guard try writerIsAccepted(for: current) else {
            try pauseAutomaticBackup()
            throw ICloudBackupError.differentWriter
        }
        let children = generations.filter { $0.manifest.parentGenerationID == currentID }
        guard children.count <= 1 else {
            try pauseAutomaticBackup()
            throw ICloudBackupError.forkDetected
        }
        if let committed = children.first {
            guard committed.manifest.writerID == writerID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
            try store.replace(try encoder.encode(Hint(generationID: currentID)), at: hintPath("previous"))
            try store.replace(
                try encoder.encode(Hint(generationID: committed.manifest.generationID)),
                at: hintPath("current")
            )
            try pruneGenerations(current: committed.manifest.generationID, previous: currentID)
            return generation(from: committed)
        }

        if let previousID = try readHint(named: "previous") {
            if previousID == currentID { throw ICloudBackupError.propagationPending }
            guard current.manifest.parentGenerationID == previousID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.forkDetected
            }
        }
        return nil
    }

    private func claimWriter() throws -> Bool {
        let path = "\(root)/writer.json"
        if let data = try store.read(at: path) {
            guard let marker = try? decoder.decode(WriterMarker.self, from: data),
                  marker.writerID == writerID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
            return false
        }

        do {
            try store.create(try encoder.encode(WriterMarker(writerID: writerID)), at: path)
            return true
        } catch ICloudBackupStoreError.alreadyExists {
            guard let data = try store.read(at: path),
                  let marker = try? decoder.decode(WriterMarker.self, from: data),
                  marker.writerID == writerID else {
                try pauseAutomaticBackup()
                throw ICloudBackupError.differentWriter
            }
            return false
        }
    }

    private func generation(from generation: ValidatedGeneration) -> ICloudBackupGeneration {
        ICloudBackupGeneration(id: generation.manifest.generationID, createdAt: generation.createdAt)
    }

    private func writerIsAccepted(for generation: ValidatedGeneration) throws -> Bool {
        if generation.manifest.writerID == writerID { return true }
        return try stateStore.acceptedTakeoverGeneration(namespace: keyID)
            == generation.manifest.generationID
    }

    private func pauseAutomaticBackup() throws {
        paused = true
        try stateStore.setAutomaticBackupPaused(true, namespace: keyID)
    }

    private func pruneGenerations(current: String, previous: String?) throws {
        let retained = Set([current, previous].compactMap { $0 })
        for path in try store.list(prefix: "\(root)/generations/") {
            let components = path.split(separator: "/")
            guard components.count >= 2 else { continue }
            if !retained.contains(String(components[components.count - 2])) {
                try store.delete(at: path)
            }
        }
    }

    private func cleanOwnedPaths(_ paths: [String], primary: Error) throws {
        pendingCleanup = try validatedCleanupPaths(Array(Set(paths)).sorted())
        var diagnostics: [String] = []
        do {
            try stateStore.setPendingCleanupPaths(pendingCleanup, namespace: keyID)
        } catch {
            diagnostics.append("record: \(error)")
        }

        var remaining: [String] = []
        for path in pendingCleanup {
            do {
                try store.delete(at: path)
            } catch {
                remaining.append(path)
                diagnostics.append("\(path): \(error)")
            }
        }
        pendingCleanup = remaining
        do {
            try stateStore.setPendingCleanupPaths(remaining, namespace: keyID)
        } catch {
            diagnostics.append("update: \(error)")
        }
        guard diagnostics.isEmpty else {
            throw ICloudBackupError.cleanupFailed(
                primary: String(describing: primary),
                cleanup: diagnostics.joined(separator: "; ")
            )
        }
    }

    private func validatedCleanupPaths(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { return [] }
        let current = try readHint(named: "current")
        let previous = try readHint(named: "previous")
        let protected = Set([current, previous].compactMap { $0 })
        var generationIDs = Set<String>()
        var claimParents: [String?] = []
        var existingPaths: [String] = []

        for path in paths {
            guard path.hasPrefix("\(root)/") else { throw ICloudBackupError.invalidCleanupState }
            guard try store.read(at: path) != nil else { continue }
            existingPaths.append(path)
            let relative = String(path.dropFirst(root.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            if components == ["writer.json"] {
                guard current == nil else { throw ICloudBackupError.invalidCleanupState }
            } else if components.count == 3,
                      components[0] == "generations",
                      (components[2] == "blob" || components[2] == "manifest.json") {
                let generationID = components[1]
                guard Self.validIdentifier(generationID), !protected.contains(generationID) else {
                    throw ICloudBackupError.invalidCleanupState
                }
                generationIDs.insert(generationID)
            } else if components.count == 2,
                      components[0] == "children",
                      components[1].hasSuffix(".json") {
                let filename = components[1]
                let parent = String(filename.dropLast(5))
                if parent == "root" {
                    claimParents.append(nil)
                } else {
                    guard Self.validIdentifier(parent) else {
                        throw ICloudBackupError.invalidCleanupState
                    }
                    claimParents.append(parent)
                }
            } else {
                throw ICloudBackupError.invalidCleanupState
            }
        }

        for parent in claimParents {
            guard let claimed = try readChildClaim(parent: parent),
                  !protected.contains(claimed) else {
                throw ICloudBackupError.invalidCleanupState
            }
            generationIDs.insert(claimed)
        }
        for generationID in generationIDs {
            do {
                _ = try validatedGeneration(generationID)
                throw ICloudBackupError.invalidCleanupState
            } catch ICloudBackupError.invalidGeneration {
                continue
            }
        }
        return existingPaths
    }

    private func readHint(named name: String) throws -> String? {
        guard let data = try store.read(at: hintPath(name)) else { return nil }
        let value: String
        do {
            value = try decoder.decode(Hint.self, from: data).generationID
        } catch {
            throw ICloudBackupError.invalidGeneration(name)
        }
        guard Self.validIdentifier(value) else { throw ICloudBackupError.invalidGeneration(name) }
        return value
    }

    private func encryptionKey() -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: recoveryKey.bytes),
            salt: Data(keyID.utf8),
            info: Data("Ask Key iCloud backup v1".utf8),
            outputByteCount: 32
        )
    }

    private func manifestPath(_ generationID: String) -> String {
        "\(root)/generations/\(generationID)/manifest.json"
    }

    private func blobPath(_ generationID: String) -> String {
        "\(root)/generations/\(generationID)/blob"
    }

    private func hintPath(_ name: String) -> String { "\(root)/\(name).json" }

    private func childClaimPath(_ parent: String?) -> String {
        "\(root)/children/\(parent ?? "root").json"
    }

    private func readChildClaim(parent: String?) throws -> String? {
        guard let data = try store.read(at: childClaimPath(parent)) else { return nil }
        do {
            let generationID = try decoder.decode(ChildClaim.self, from: data).generationID
            guard Self.validIdentifier(generationID) else {
                throw ICloudBackupError.invalidGeneration("child claim")
            }
            return generationID
        } catch let error as ICloudBackupError {
            throw error
        } catch {
            throw ICloudBackupError.invalidGeneration("child claim")
        }
    }

    private static func authenticatedFields(
        formatVersion: Int,
        generationID: String,
        keyID: String,
        writerID: String,
        parentGenerationID: String?,
        createdAt: String
    ) -> Data {
        Data("\(formatVersion)\n\(generationID)\n\(keyID)\n\(writerID)\n\(parentGenerationID ?? "-")\n\(createdAt)".utf8)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        }
    }

    private static func hex<T: DataProtocol>(_ data: T) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
