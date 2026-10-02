import Foundation
import AskKeyBrokerC
#if canImport(Darwin)
import Darwin
#endif

public struct BrokerPassedFileDescriptors: Sendable {
    public let standardInput: Int32
    public let standardOutput: Int32
    public let standardError: Int32
    public let control: Int32

    public init(standardInput: Int32, standardOutput: Int32, standardError: Int32, control: Int32) {
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.control = control
    }
}

public struct BrokerTextRunRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let command: [String]
    public let credentialNames: [String]
    public let workingDirectory: String?
    public let inheritedEnvironment: [String: String]
    /// Self-declared caller label. Never an authorization or identity input.
    public let callerName: String?
    /// Self-declared purpose. Never an authorization or identity input.
    public let callerPurpose: String?

    public init(
        operationID: String = UUID().uuidString,
        command: [String],
        credentialNames: [String],
        workingDirectory: String? = nil,
        inheritedEnvironment: [String: String] = [:],
        callerName: String? = nil,
        callerPurpose: String? = nil
    ) {
        self.operationID = operationID
        self.command = command
        self.credentialNames = credentialNames
        self.workingDirectory = workingDirectory
        self.inheritedEnvironment = inheritedEnvironment
        self.callerName = Self.sanitizedDeclaration(callerName)
        self.callerPurpose = Self.sanitizedDeclaration(callerPurpose)
    }

    enum CodingKeys: String, CodingKey {
        case operationID, command, credentialNames, workingDirectory
        case inheritedEnvironment, callerName, callerPurpose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try container.decode(String.self, forKey: .operationID)
        command = try container.decode([String].self, forKey: .command)
        credentialNames = try container.decode([String].self, forKey: .credentialNames)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        inheritedEnvironment = try container.decodeIfPresent([String: String].self, forKey: .inheritedEnvironment) ?? [:]
        callerName = Self.sanitizedDeclaration(try container.decodeIfPresent(String.self, forKey: .callerName))
        callerPurpose = Self.sanitizedDeclaration(try container.decodeIfPresent(String.self, forKey: .callerPurpose))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(command, forKey: .command)
        try container.encode(credentialNames, forKey: .credentialNames)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(inheritedEnvironment, forKey: .inheritedEnvironment)
        try container.encodeIfPresent(callerName, forKey: .callerName)
        try container.encodeIfPresent(callerPurpose, forKey: .callerPurpose)
    }

    public var sanitizedCallerName: String? { Self.sanitizedDeclaration(callerName) }
    public var sanitizedCallerPurpose: String? { Self.sanitizedDeclaration(callerPurpose) }

    public var declarationsAreValid: Bool {
        [callerName, callerPurpose].allSatisfy(Self.validDeclaration)
    }

    static func sanitizedDeclaration(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func validDeclaration(_ raw: String?) -> Bool {
        guard let value = sanitizedDeclaration(raw) else { return true }
        return value.utf8.count <= BrokerLimits.maximumFieldBytes
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    public static func filteredInheritedEnvironment(
        _ environment: [String: String]
    ) -> [String: String] {
        environment.filter { inheritedEnvironmentKey($0.key) }
    }

    private static func inheritedEnvironmentKey(_ key: String) -> Bool {
        ["HOME", "PATH", "TMPDIR", "LANG", "TERM", "SHELL", "USER", "LOGNAME"].contains(key)
            || key.hasPrefix("LC_")
    }
}

public struct BrokerTextCredential: Equatable, Sendable {
    public let environmentVariable: String
    public let value: String

    public init(environmentVariable: String, value: String) {
        self.environmentVariable = environmentVariable
        self.value = value
    }
}

/// Holds the Vault's agent-delivery gate through the exact spawn boundary.
/// Deinitialization safely releases an abandoned lease.
public final class BrokerTextDeliveryLease: @unchecked Sendable {
    public let spawnDeadline: Date?
    private let lock = NSLock()
    private let beginSpawnAuthorization: () throws -> Void
    private let validate: () throws -> Void
    private let endSpawnAuthorization: () -> Void
    private let runtimeAuthorization: BrokerRuntimeReadAuthorization?
    private var finishAction: (() -> Void)?
    private var cleanupAction: (() -> Void)?

    public init(
        beginSpawnAuthorization: @escaping () throws -> Void,
        validate: @escaping () throws -> Void,
        endSpawnAuthorization: @escaping () -> Void,
        spawnDeadline: Date?,
        runtimeAuthorization: BrokerRuntimeReadAuthorization? = nil,
        finish: @escaping () -> Void,
        cleanup: @escaping () -> Void = {}
    ) {
        self.spawnDeadline = spawnDeadline
        self.beginSpawnAuthorization = beginSpawnAuthorization
        self.validate = validate
        self.endSpawnAuthorization = endSpawnAuthorization
        self.runtimeAuthorization = runtimeAuthorization
        finishAction = finish
        cleanupAction = cleanup
    }

    deinit { finish(); cleanup() }

    public func performAuthorizedSpawn<T>(
        afterAuthorization: () throws -> Void,
        spawn: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard finishAction != nil else { throw BrokerTextRuntimeError.invalidRequest }
        try beginSpawnAuthorization()
        defer { endSpawnAuthorization() }
        if let runtimeAuthorization {
            // Lock order is lease -> Vault gate -> approval. Revocation never
            // acquires the Vault gate or waits for this lease's active operation.
            return try runtimeAuthorization.performAuthorizedSpawn {
                try afterAuthorization()
                try validate()
                return try spawn()
            }
        }
        try afterAuthorization()
        try validate()
        return try spawn()
    }

    public func finish() {
        lock.lock()
        let action = finishAction
        finishAction = nil
        lock.unlock()
        action?()
    }

    public func cleanup() {
        lock.lock()
        let action = cleanupAction
        cleanupAction = nil
        lock.unlock()
        action?()
        runtimeAuthorization?.finish()
    }
}

public enum BrokerTextRunResult: Codable, Equatable, Sendable {
    case exited(Int32)
    case approvalRequired(operationID: String, tickets: [BrokerApprovalTicket])
    case outcomeUnknown
}

public enum BrokerTextCredentialResolution: Sendable {
    case resolved(
        credentials: [BrokerTextCredential],
        resolvedRequestCount: Int,
        deliveryLease: BrokerTextDeliveryLease?
    )
    case approvalRequired([BrokerApprovalTicket])

    public static func resolved(
        _ credentials: [BrokerTextCredential],
        resolvedRequestCount: Int? = nil
    ) -> Self {
        .resolved(
            credentials: credentials,
            resolvedRequestCount: resolvedRequestCount ?? (credentials.isEmpty ? 0 : 1),
            deliveryLease: nil
        )
    }
}

public enum BrokerRuntimeSignal: UInt8, Sendable {
    case interrupt = 2
    case terminate = 15
}

public enum BrokerTextRuntimeError: Error, Equatable {
    case missingCommand
    case missingCredentials
    case invalidRequest
    case invalidWorkingDirectory
    case invalidCredentialMapping
    case spawnFailed
}

/// Starts the target directly from the Broker. Target streams remain connected to
/// caller-owned descriptors; this type never reads or buffers their contents.
public final class BrokerTextRuntime: @unchecked Sendable {
    public typealias CredentialResolver = @Sendable (BrokerTextRunRequest, BrokerCancellation) throws -> BrokerTextCredentialResolution
    public typealias SpawnBoundaryHook = @Sendable () throws -> Void

    private let operations: BrokerRuntimeOperations
    private let resolveCredentials: CredentialResolver
    private let beforeSpawn: SpawnBoundaryHook
    private let afterAuthorization: SpawnBoundaryHook
    private let beforeSystemSpawn: SpawnBoundaryHook
    private let afterSpawn: SpawnBoundaryHook
    private let terminationGrace: TimeInterval
    private let forceKillGrace: TimeInterval

    public init(
        resolveCredentials: @escaping CredentialResolver,
        beforeSpawn: @escaping SpawnBoundaryHook = {},
        afterAuthorization: @escaping SpawnBoundaryHook = {},
        beforeSystemSpawn: @escaping SpawnBoundaryHook = {},
        afterSpawn: @escaping SpawnBoundaryHook = {},
        terminationGrace: TimeInterval = 0.5,
        forceKillGrace: TimeInterval = 1,
        receiptCapacity: Int = BrokerLimits.maximumRuntimeReceiptCount
    ) {
        self.operations = BrokerRuntimeOperations(receiptCapacity: receiptCapacity)
        self.resolveCredentials = resolveCredentials
        self.beforeSpawn = beforeSpawn
        self.afterAuthorization = afterAuthorization
        self.beforeSystemSpawn = beforeSystemSpawn
        self.afterSpawn = afterSpawn
        self.terminationGrace = Self.validDuration(terminationGrace) ? terminationGrace : 0.5
        self.forceKillGrace = Self.validDuration(forceKillGrace) ? forceKillGrace : 1
    }

    static func validateRequestBeforeReceipt(_ request: BrokerTextRunRequest) throws {
        guard !request.command.isEmpty else { throw BrokerTextRuntimeError.missingCommand }
        guard !request.credentialNames.isEmpty else { throw BrokerTextRuntimeError.missingCredentials }
        guard Self.validField(request.operationID),
              request.command.allSatisfy(Self.validField),
              request.credentialNames.allSatisfy(Self.validField),
              Set(request.credentialNames).count == request.credentialNames.count,
              request.declarationsAreValid,
              BrokerTextRunRequest.filteredInheritedEnvironment(request.inheritedEnvironment)
                  .values.allSatisfy({ !$0.contains("\0") }) else {
            throw BrokerTextRuntimeError.invalidRequest
        }
        if let directory = request.workingDirectory {
            guard Self.validField(directory), directory.hasPrefix("/") else {
                throw BrokerTextRuntimeError.invalidWorkingDirectory
            }
        }
    }

    public func run(
        _ request: BrokerTextRunRequest,
        standardInputFD: Int32 = FileHandle.standardInput.fileDescriptor,
        standardOutputFD: Int32 = FileHandle.standardOutput.fileDescriptor,
        standardErrorFD: Int32 = FileHandle.standardError.fileDescriptor,
        controlFD: Int32? = nil,
        cancellation: BrokerCancellation = BrokerCancellation()
    ) throws -> BrokerTextRunResult {
        try operations.perform(request, cancellation: cancellation) {
            try runOnce(
                request,
                standardInputFD: standardInputFD,
                standardOutputFD: standardOutputFD,
                standardErrorFD: standardErrorFD,
                controlFD: controlFD,
                cancellation: cancellation
            )
        }
    }

    private func runOnce(
        _ request: BrokerTextRunRequest,
        standardInputFD: Int32,
        standardOutputFD: Int32,
        standardErrorFD: Int32,
        controlFD: Int32?,
        cancellation: BrokerCancellation
    ) throws -> BrokerTextRunResult {
        if let directory = request.workingDirectory {
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw BrokerTextRuntimeError.invalidWorkingDirectory
            }
        }
        let credentials: [BrokerTextCredential]
        let resolvedRequestCount: Int
        let deliveryLease: BrokerTextDeliveryLease?
        switch try resolveCredentials(request, cancellation) {
        case .resolved(let resolved, let count, let lease):
            credentials = resolved
            resolvedRequestCount = count
            deliveryLease = lease
        case .approvalRequired(let tickets):
            return .approvalRequired(operationID: request.operationID, tickets: tickets)
        }
        defer { deliveryLease?.finish(); deliveryLease?.cleanup() }
        guard resolvedRequestCount == request.credentialNames.count,
              credentials.allSatisfy({ Self.validEnvironmentName($0.environmentVariable) }),
              Set(credentials.map(\.environmentVariable)).count == credentials.count else {
            throw BrokerTextRuntimeError.invalidCredentialMapping
        }

        var environment = BrokerTextRunRequest.filteredInheritedEnvironment(request.inheritedEnvironment)
        for credential in credentials { environment[credential.environmentVariable] = credential.value }
        guard environment.values.allSatisfy({ !$0.contains("\0") }) else {
            throw BrokerTextRuntimeError.invalidCredentialMapping
        }

        try beforeSpawn()
        let spawnProcess = {
            try cancellation.check()
            return try self.spawn(
                request: request,
                environment: environment,
                standardInputFD: standardInputFD,
                standardOutputFD: standardOutputFD,
                standardErrorFD: standardErrorFD,
                deadline: deliveryLease?.spawnDeadline
            )
        }
        let process: BrokerSpawnedProcess
        if let deliveryLease {
            process = try deliveryLease.performAuthorizedSpawn(
                afterAuthorization: afterAuthorization,
                spawn: spawnProcess
            )
        } else {
            try afterAuthorization()
            process = try spawnProcess()
        }
        deliveryLease?.finish()
        let controlSource = controlFD.map { descriptor in
            let source = DispatchSource.makeReadSource(
                fileDescriptor: descriptor,
                queue: DispatchQueue(label: "com.sudohg.askkey.runtime-control")
            )
            source.setEventHandler {
                var byte: UInt8 = 0
                let count = read(descriptor, &byte, 1)
                if count == 0 {
                    cancellation.cancel()
                } else if count == 1, let signal = BrokerRuntimeSignal(rawValue: byte) {
                    _ = process.send(Int32(signal.rawValue))
                }
            }
            source.resume()
            return source
        }
        defer { controlSource?.cancel() }
        do {
            try afterSpawn()
        } catch {
            _ = terminate(process)
            return .outcomeUnknown
        }
        while true {
            let leaderExited = process.pollExit()
            if cancellation.isCancelled {
                if process.groupExists, !terminate(process) { return .outcomeUnknown }
                break
            }
            if leaderExited, !process.groupExists { break }
            usleep(10_000)
        }
        guard let exitCode = process.exitCode else { return .outcomeUnknown }
        return .exited(exitCode)
    }

    private static func validField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= BrokerLimits.maximumFieldBytes && !value.contains("\0")
    }

    private func terminate(_ process: BrokerSpawnedProcess) -> Bool {
        _ = process.send(SIGTERM)
        if waitUntilGroupStops(process, timeout: terminationGrace) { return true }
        _ = process.send(SIGKILL)
        return waitUntilGroupStops(process, timeout: forceKillGrace)
    }

    private func waitUntilGroupStops(_ process: BrokerSpawnedProcess, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let leaderExited = process.pollExit()
            if leaderExited, !process.groupExists { return true }
            usleep(10_000)
        }
        return process.pollExit() && !process.groupExists
    }

    private func spawn(
        request: BrokerTextRunRequest,
        environment: [String: String],
        standardInputFD: Int32,
        standardOutputFD: Int32,
        standardErrorFD: Int32,
        deadline: Date?
    ) throws -> BrokerSpawnedProcess {
        let arguments = ["env"] + request.command
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
        return try withCStringArray(arguments) { argumentPointers in
            try withCStringArray(environmentEntries) { environmentPointers in
                var pid: pid_t = 0
                try beforeSystemSpawn()
                let deadlineInterval = deadline?.timeIntervalSince1970 ?? -1
                let deadlineSeconds = Int64(deadlineInterval.rounded(.down))
                let deadlineNanoseconds = deadlineInterval < 0
                    ? 0
                    : min(999_999_999, max(
                        0,
                        Int64((deadlineInterval - Double(deadlineSeconds)) * 1_000_000_000)
                    ))
                let result = request.workingDirectory?.withCString { directory in
                    askkey_spawn_process_group(
                        "/usr/bin/env", argumentPointers, environmentPointers,
                        standardInputFD, standardOutputFD, standardErrorFD, directory,
                        deadlineSeconds, deadlineNanoseconds, &pid
                    )
                } ?? askkey_spawn_process_group(
                    "/usr/bin/env", argumentPointers, environmentPointers,
                    standardInputFD, standardOutputFD, standardErrorFD, nil,
                    deadlineSeconds, deadlineNanoseconds, &pid
                )
                if result == ETIMEDOUT { throw BrokerProviderError.requestRejected }
                guard result == 0 else { throw BrokerTextRuntimeError.spawnFailed }
                return BrokerSpawnedProcess(pid: pid)
            }
        }
    }

    private func withCStringArray<T>(
        _ strings: [String],
        body: ([UnsafeMutablePointer<CChar>?]) throws -> T
    ) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { pointers.compactMap { $0 }.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw BrokerTextRuntimeError.spawnFailed }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try body(pointers)
    }

    private static func validDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0 && value <= 60
    }

    private static func validEnvironmentName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains($0)
        }
    }

}

private final class BrokerSpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    private var waitStatus: Int32?
    private var waitError: Int32?

    init(pid: pid_t) { self.pid = pid }

    func send(_ signal: Int32) -> Bool {
        if kill(-pid, signal) == 0 { return true }
        guard errno == ESRCH else { return false }
        if kill(pid, signal) == 0 { return true }
        return errno == ESRCH
    }

    var groupExists: Bool {
        if kill(-pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    func pollExit() -> Bool {
        if waitStatus != nil || waitError != nil { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            waitStatus = status
            return true
        }
        if result < 0, errno != EINTR {
            waitError = errno
            return true
        }
        return false
    }

    var exitCode: Int32? {
        guard let status = waitStatus else { return nil }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
