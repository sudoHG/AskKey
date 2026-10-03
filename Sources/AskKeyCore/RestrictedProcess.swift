import Foundation
#if canImport(Darwin)
import Darwin
#endif

#if DEBUG
/// DEBUG-only onboarding observation. Not compiled into Release Core.
/// `note` records when a check/apply task set `active`, or when an isolated
/// page window is open.
public enum OnboardingBoundaryObserver {
    public enum Kind: String, Sendable {
        case cli
        case keychain
        case configWrite
        case cursorHelper
    }

    @TaskLocal public static var active = false

    private static let windowLock = NSLock()
    private static var pageWindow = false

    public static func beginPageWindow() {
        windowLock.withLock { pageWindow = true }
    }

    public static func endPageWindow() {
        windowLock.withLock { pageWindow = false }
    }

    public static var isPageWindowActive: Bool {
        windowLock.withLock { pageWindow }
    }

    public static let emptySnapshot: [String: Int] = [
        "cli": 0, "keychain": 0, "configWrite": 0, "cursorHelper": 0
    ]

    public final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Kind: Int] = [:]

        public init() {}

        public func add(_ kind: Kind) {
            lock.withLock { counts[kind, default: 0] += 1 }
        }

        public func count(_ kind: Kind) -> Int {
            lock.withLock { counts[kind, default: 0] }
        }

        public var snapshot: [String: Int] {
            lock.withLock {
                [
                    "cli": counts[.cli, default: 0],
                    "keychain": counts[.keychain, default: 0],
                    "configWrite": counts[.configWrite, default: 0],
                    "cursorHelper": counts[.cursorHelper, default: 0]
                ]
            }
        }

        public func reset() {
            lock.withLock { counts = [:] }
        }
    }

    private static let lock = NSLock()
    private static var installed: Recorder?

    public static func install(_ recorder: Recorder?) {
        lock.withLock { installed = recorder }
    }

    public static func note(_ kind: Kind) {
        guard active || isPageWindowActive else { return }
        lock.withLock { installed }?.add(kind)
    }

    public static func count(_ kind: Kind) -> Int {
        lock.withLock { installed?.count(kind) ?? 0 }
    }

    public static var snapshot: [String: Int] {
        lock.withLock { installed?.snapshot ?? emptySnapshot }
    }

    public static func probeRejectedKeychain() {
        do { _ = try KeychainStore.load() } catch {}
    }

    public static func probeIsolatedCLI() throws {
        _ = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2,
                maximumOutputBytes: 64
            )
        )
    }

    public static func probeIsolatedConfigWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e1-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try ClientConfigFileIO.publishAtomically(
            Data("x = 1\n".utf8),
            to: directory.appendingPathComponent("config.toml"),
            mode: 0o600,
            exclusive: true,
            temporaryPrefix: ".askkey-e1-"
        )
    }

    public static func probeCursorHelperLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-cursor-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("cursor-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let adapter = CursorUserMCPAdapter(
            homeDirectory: directory,
            backupDirectory: directory.appendingPathComponent("backup", isDirectory: true),
            helperURL: helper,
            brokerSocketPath: directory.appendingPathComponent("broker.sock").path,
            signing: .development
        )
        adapter.probeHelperProcessForEvidence()
    }
}
#endif

/// Shared posix_spawn + private process-group + CLOEXEC + wait + group cleanup.
/// Codex and Grok keep their own timeouts, cwd, stderr, input timing, overflow,
/// and TERM grace. Cursor's long-lived Foundation Process path stays separate.
package enum RestrictedProcess {
    package static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws {
        _ = try run(Request(executable: executable, arguments: arguments,
                            environment: environment, timeout: timeout,
                            maximumOutputBytes: maximumOutputBytes))
    }

    struct Request: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL? = nil
        var standardInput: Data? = nil
        var writeInputBeforeSpawn = false
        var maximumInputBytes: Int? = nil
        var timeout: TimeInterval
        var usesMonotonicClock = false
        var captureStderr = true
        var maximumOutputBytes: Int
        var truncateOutput = true
        var terminationGrace: TimeInterval = 0
        var isCancelled: (@Sendable () -> Bool)? = nil
    }

    struct Result: Equatable, Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    enum Failure: Error, Equatable {
        case cancelled
        case inputTooLarge
        case outputTooLarge
        case spawnFailed(POSIXErrorCode)
        case ioFailed(POSIXErrorCode)

        var posixError: POSIXError {
            switch self {
            case .cancelled:
                return POSIXError(.ECANCELED)
            case .inputTooLarge, .outputTooLarge:
                return POSIXError(.EIO)
            case .spawnFailed(let code), .ioFailed(let code):
                return POSIXError(code)
            }
        }

        static func capturedSpawn(_ code: Int32 = errno) -> Failure {
            .spawnFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        static func capturedIO(_ code: Int32 = errno) -> Failure {
            .ioFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func run(_ request: Request) throws -> Result {
        if let limit = request.maximumInputBytes,
           let input = request.standardInput,
           input.count > limit {
            throw Failure.inputTooLarge
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        let stdoutAcc = ByteAccumulator(maximumBytes: request.maximumOutputBytes)
        let stderrAcc = ByteAccumulator(maximumBytes: request.maximumOutputBytes)
        let outRead = stdout.fileHandleForReading.fileDescriptor
        let errRead = stderr.fileHandleForReading.fileDescriptor
        let inWrite = stdin.fileHandleForWriting.fileDescriptor
        defer {
            for handle in [
                stdout.fileHandleForReading, stdout.fileHandleForWriting,
                stderr.fileHandleForReading, stderr.fileHandleForWriting,
                stdin.fileHandleForReading, stdin.fileHandleForWriting,
            ] {
                try? handle.close()
            }
        }

        guard fcntl(outRead, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.capturedIO() }
        if request.captureStderr {
            guard fcntl(errRead, F_SETFL, O_NONBLOCK) != -1 else { throw Failure.capturedIO() }
        }
        if request.standardInput != nil, !request.writeInputBeforeSpawn {
            guard fcntl(inWrite, F_SETNOSIGPIPE, 1) != -1 else { throw Failure.capturedIO() }
        }

        if request.writeInputBeforeSpawn, let input = request.standardInput {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let initializedActions = posix_spawn_file_actions_init(&actions)
        guard initializedActions == 0 else { throw Failure.capturedSpawn(initializedActions) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let initializedAttributes = posix_spawnattr_init(&attributes)
        guard initializedAttributes == 0 else { throw Failure.capturedSpawn(initializedAttributes) }
        defer { posix_spawnattr_destroy(&attributes) }

        let nullInput: Int32
        let stdinSource: Int32
        if request.standardInput != nil {
            nullInput = -1
            stdinSource = stdin.fileHandleForReading.fileDescriptor
        } else {
            nullInput = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard nullInput >= 0 else { throw Failure.capturedSpawn() }
            stdinSource = nullInput
        }
        defer { if nullInput >= 0 { _ = Darwin.close(nullInput) } }

        let setGroup = posix_spawnattr_setpgroup(&attributes, 0)
        guard setGroup == 0 else { throw Failure.capturedSpawn(setGroup) }
        let setFlags = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        guard setFlags == 0 else { throw Failure.capturedSpawn(setFlags) }
        if let directory = request.currentDirectory {
            let chdir = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            guard chdir == 0 else { throw Failure.capturedSpawn(chdir) }
        }
        let dupIn = posix_spawn_file_actions_adddup2(&actions, stdinSource, STDIN_FILENO)
        guard dupIn == 0 else { throw Failure.capturedSpawn(dupIn) }
        let dupOut = posix_spawn_file_actions_adddup2(
            &actions,
            stdout.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        )
        guard dupOut == 0 else { throw Failure.capturedSpawn(dupOut) }
        if request.captureStderr {
            let dupErr = posix_spawn_file_actions_adddup2(
                &actions,
                stderr.fileHandleForWriting.fileDescriptor,
                STDERR_FILENO
            )
            guard dupErr == 0 else { throw Failure.capturedSpawn(dupErr) }
        } else {
            let openErr = posix_spawn_file_actions_addopen(
                &actions,
                STDERR_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
            guard openErr == 0 else { throw Failure.capturedSpawn(openErr) }
        }

        var argv = ([request.executable.path] + request.arguments).map { strdup($0) }
        var envp = request.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw Failure.capturedSpawn(ENOMEM)
        }
        argv.append(nil)
        envp.append(nil)

        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { env in
                guard let argBase = args.baseAddress, let envBase = env.baseAddress else {
                    return Int32(ENOMEM)
                }
                return posix_spawn(
                    &pid,
                    request.executable.path,
                    &actions,
                    &attributes,
                    argBase,
                    envBase
                )
            }
        }
        guard spawned == 0, pid > 1, pid != getpid() else {
            throw Failure.capturedSpawn(spawned == 0 ? EIO : spawned)
        }
#if DEBUG
        OnboardingBoundaryObserver.note(.cli)
#endif

        var reaped = false
        defer {
            if !reaped {
                stopProcessGroup(pid, grace: 0)
                reapProcess(pid)
            }
        }

        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()
        try stdin.fileHandleForReading.close()
        if !request.writeInputBeforeSpawn {
            if let input = request.standardInput {
                try stdin.fileHandleForWriting.write(contentsOf: input)
            }
            try stdin.fileHandleForWriting.close()
        }

        let start = now(monotonic: request.usesMonotonicClock)
        var exited = false
        var terminationStatus: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while now(monotonic: request.usesMonotonicClock) < start + request.timeout {
            if request.isCancelled?() == true || RestrictedProcessCancellation.current?() == true {
                stopProcessGroup(pid, grace: 0)
                reapProcess(pid)
                reaped = true
                throw Failure.cancelled
            }
            if !exited, let status = peekExit(pid) {
                exited = true
                terminationStatus = status
            }
            do {
                let readAny = try drain(
                    stdout: outRead,
                    stderr: request.captureStderr ? errRead : nil,
                    buffer: &buffer,
                    stdoutAcc: stdoutAcc,
                    stderrAcc: stderrAcc,
                    truncate: request.truncateOutput
                )
                if exited, !readAny { break }
                if !readAny { Thread.sleep(forTimeInterval: 0.005) }
            } catch {
                stopProcessGroup(pid, grace: 0)
                reapProcess(pid)
                reaped = true
                throw error
            }
        }

        let timedOut = !exited
        if timedOut {
            stopProcessGroup(pid, grace: max(request.terminationGrace, 0))
            if let status = peekExit(pid) {
                exited = true
                terminationStatus = status
            }
        } else if processGroupExists(pid) {
            stopProcessGroup(pid, grace: 0)
        }
        reapProcess(pid)
        reaped = true
        _ = try drain(
            stdout: outRead,
            stderr: request.captureStderr ? errRead : nil,
            buffer: &buffer,
            stdoutAcc: stdoutAcc,
            stderrAcc: stderrAcc,
            truncate: request.truncateOutput
        )
        return Result(
            status: exited ? terminationStatus : 0,
            stdout: stdoutAcc.data,
            stderr: stderrAcc.data,
            timedOut: timedOut
        )
    }
}

private final class ByteAccumulator {
    let maximumBytes: Int
    private var storage = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data, truncate: Bool) throws {
        guard !data.isEmpty else { return }
        if storage.count >= maximumBytes {
            if truncate { return }
            throw RestrictedProcess.Failure.outputTooLarge
        }
        let allowed = min(data.count, maximumBytes - storage.count)
        if allowed > 0 {
            storage.append(data.prefix(allowed))
        }
        if !truncate, allowed < data.count {
            throw RestrictedProcess.Failure.outputTooLarge
        }
    }

    var data: Data { storage }
}

private func now(monotonic: Bool) -> TimeInterval {
    monotonic
        ? ProcessInfo.processInfo.systemUptime
        : Date().timeIntervalSinceReferenceDate
}

private func peekExit(_ pid: pid_t) -> Int32? {
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result != 0, errno != EINTR { return nil }
    if result == 0, info.si_pid == pid {
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }
    return nil
}

private func drain(
    stdout: Int32,
    stderr: Int32?,
    buffer: inout [UInt8],
    stdoutAcc: ByteAccumulator,
    stderrAcc: ByteAccumulator,
    truncate: Bool
) throws -> Bool {
    var readAny = false
    let pipes: [(Int32, ByteAccumulator)]
    if let stderr {
        pipes = [(stdout, stdoutAcc), (stderr, stderrAcc)]
    } else {
        pipes = [(stdout, stdoutAcc)]
    }
    for (descriptor, accumulator) in pipes {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, raw.count)
        }
        if count > 0, count <= buffer.count {
            readAny = true
            try accumulator.append(Data(buffer[0..<count]), truncate: truncate)
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw RestrictedProcess.Failure.capturedIO()
        }
    }
    return readAny
}

private func processGroupExists(_ pid: pid_t) -> Bool {
    guard pid > 1, pid != getpid() else { return false }
    if kill(-pid, 0) == 0 { return true }
    return errno != ESRCH
}

private func stopProcessGroup(_ pid: pid_t, grace: TimeInterval) {
    guard pid > 1, pid != getpid() else { return }
    _ = kill(-pid, SIGTERM)
    if grace > 0 {
        waitUntilGroupStops(pid, until: Date().addingTimeInterval(grace))
    }
    if processGroupExists(pid) {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        if grace > 0 {
            waitUntilGroupStops(pid, until: Date().addingTimeInterval(grace))
        }
    }
}

private func waitUntilGroupStops(_ pid: pid_t, until deadline: Date) {
    while Date() < deadline, processGroupExists(pid) {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

private func reapProcess(_ pid: pid_t) {
    guard pid > 1 else { return }
    var status: Int32 = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while ProcessInfo.processInfo.systemUptime < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno != EINTR) { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

// MARK: - Interactive restricted process

extension RestrictedProcess {
    /// The small interactive boundary used by native app-server clients.
    ///
    /// This deliberately shares the same spawn topology as `run`: the child
    /// gets a private process group, inherited descriptors are closed by
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, and cleanup always covers the group.
    /// It is line-oriented because app-server speaks JSONL, and it never uses
    /// Foundation's `Process` abstraction.
    struct InteractiveRequest: Sendable {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: URL? = nil
        var timeout: TimeInterval
        var maximumInputBytes: Int
        var maximumOutputBytes: Int
        var terminationGrace: TimeInterval = 0
        var isCancelled: (@Sendable () -> Bool)? = nil
    }

    enum InteractiveFailure: Error, Equatable {
        case cancelled
        case timedOut
        case inputTooLarge
        case outputTooLarge
        case processExited(Int32)
        case spawnFailed(POSIXErrorCode)
        case ioFailed(POSIXErrorCode)

        static func capturedSpawn(_ code: Int32 = errno) -> Self {
            .spawnFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        static func capturedIO(_ code: Int32 = errno) -> Self {
            .ioFailed(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A synchronous JSONL transport. Callers own one session on one thread.
    final class InteractiveSession: @unchecked Sendable {
        private let pid: pid_t
        private let input: FileHandle
        private let output: FileHandle
        private let inputDescriptor: Int32
        private let outputDescriptor: Int32
        private let timeout: TimeInterval
        private let maximumInputBytes: Int
        private let maximumOutputBytes: Int
        private let terminationGrace: TimeInterval
        private let isCancelled: (@Sendable () -> Bool)?
        private var pendingOutput = Data()
        private var totalOutputBytes = 0
        private var activeDeadline: TimeInterval?
        private var closed = false
        private let closeLock = NSLock()

        init(
            pid: pid_t,
            input: FileHandle,
            output: FileHandle,
            timeout: TimeInterval,
            maximumInputBytes: Int,
            maximumOutputBytes: Int,
            terminationGrace: TimeInterval,
            isCancelled: (@Sendable () -> Bool)?
        ) {
            self.pid = pid
            self.input = input
            self.output = output
            inputDescriptor = input.fileDescriptor
            outputDescriptor = output.fileDescriptor
            self.timeout = timeout
            self.maximumInputBytes = maximumInputBytes
            self.maximumOutputBytes = maximumOutputBytes
            self.terminationGrace = terminationGrace
            self.isCancelled = isCancelled
        }

        deinit {
            close()
        }

        func writeLine(_ data: Data) throws {
            try ensureOpen()
            var line = data
            if line.last != 0x0A { line.append(0x0A) }
            guard line.count <= maximumInputBytes else {
                closeAfterFailure()
                throw InteractiveFailure.inputTooLarge
            }
            let deadline = ProcessInfo.processInfo.systemUptime + max(timeout, 0)
            activeDeadline = deadline
            try write(line, until: deadline)
        }

        func readLine() throws -> Data {
            try ensureOpen()
            let deadline = activeDeadline
                ?? (ProcessInfo.processInfo.systemUptime + max(timeout, 0))
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)

            while true {
                try checkCancellation(until: deadline)
                if let newline = pendingOutput.firstIndex(of: 0x0A) {
                    var line = Data(pendingOutput[..<newline])
                    pendingOutput.removeSubrange(...newline)
                    if line.last == 0x0D { line.removeLast() }
                    return line
                }
                guard pendingOutput.count <= maximumOutputBytes else {
                    closeAfterFailure()
                    throw InteractiveFailure.outputTooLarge
                }
                try waitForOutput(until: deadline)
                let count = chunk.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.read(outputDescriptor, base, raw.count)
                }
                if count > 0 {
                    totalOutputBytes += count
                    guard totalOutputBytes <= maximumOutputBytes else {
                        closeAfterFailure()
                        throw InteractiveFailure.outputTooLarge
                    }
                    pendingOutput.append(chunk, count: count)
                    guard pendingOutput.count <= maximumOutputBytes else {
                        closeAfterFailure()
                        throw InteractiveFailure.outputTooLarge
                    }
                    continue
                }
                if count == 0 {
                    let status = peekExit(pid) ?? 0
                    closeAfterFailure()
                    throw InteractiveFailure.processExited(status)
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                closeAfterFailure()
                throw InteractiveFailure.capturedIO()
            }
        }

        func close() {
            let shouldClose = closeLock.withLock {
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            stopProcessGroup(pid, grace: terminationGrace)
            reapProcess(pid)
            try? input.close()
            try? output.close()
        }

        private func write(_ data: Data, until deadline: TimeInterval) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    try checkCancellation(until: deadline)
                    let count = Darwin.write(inputDescriptor, base.advanced(by: offset), raw.count - offset)
                    if count > 0 {
                        offset += count
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try waitForInput(until: deadline)
                        continue
                    }
                    closeAfterFailure()
                    throw InteractiveFailure.capturedIO(count < 0 ? errno : EPIPE)
                }
            }
        }

        private func ensureOpen() throws {
            let isClosed = closeLock.withLock { closed }
            if isClosed { throw InteractiveFailure.ioFailed(.EBADF) }
        }

        private func checkCancellation(until deadline: TimeInterval) throws {
            if isCancelled?() == true || RestrictedProcessCancellation.current?() == true {
                closeAfterFailure()
                throw InteractiveFailure.cancelled
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                closeAfterFailure()
                throw InteractiveFailure.timedOut
            }
        }

        private func waitForOutput(until deadline: TimeInterval) throws {
            while true {
                try checkCancellation(until: deadline)
                var descriptor = pollfd(
                    fd: outputDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let result = Darwin.poll(&descriptor, 1, pollTimeout(until: deadline))
                if result > 0 { return }
                if result == 0 { continue }
                if errno == EINTR { continue }
                closeAfterFailure()
                throw InteractiveFailure.capturedIO()
            }
        }

        private func waitForInput(until deadline: TimeInterval) throws {
            while true {
                try checkCancellation(until: deadline)
                var descriptor = pollfd(
                    fd: inputDescriptor,
                    events: Int16(POLLOUT | POLLERR | POLLHUP),
                    revents: 0
                )
                let result = Darwin.poll(&descriptor, 1, pollTimeout(until: deadline))
                if result > 0 { return }
                if result == 0 { continue }
                if errno == EINTR { continue }
                closeAfterFailure()
                throw InteractiveFailure.capturedIO()
            }
        }

        private func pollTimeout(until deadline: TimeInterval) -> Int32 {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let milliseconds = Int(ceil(remaining * 1_000))
            // Keep cancellation responsive while waiting for a quiet server.
            // The deadline remains the authoritative timeout.
            return Int32(min(max(milliseconds, 1), 50))
        }

        private func closeAfterFailure() {
            close()
        }
    }

    static func startInteractive(_ request: InteractiveRequest) throws -> InteractiveSession {
        guard request.maximumInputBytes > 0, request.maximumOutputBytes > 0 else {
            throw InteractiveFailure.ioFailed(.EINVAL)
        }

        let stdin = Pipe()
        let stdout = Pipe()
        var transferred = false
        defer {
            if !transferred {
                try? stdin.fileHandleForReading.close()
                try? stdin.fileHandleForWriting.close()
                try? stdout.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close()
            }
        }

        let inputDescriptor = stdin.fileHandleForWriting.fileDescriptor
        let outputDescriptor = stdout.fileHandleForReading.fileDescriptor
        guard fcntl(outputDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw InteractiveFailure.capturedIO()
        }
        guard fcntl(inputDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
            throw InteractiveFailure.capturedIO()
        }
        guard fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw InteractiveFailure.capturedIO()
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let initializedActions = posix_spawn_file_actions_init(&actions)
        guard initializedActions == 0 else { throw InteractiveFailure.capturedSpawn(initializedActions) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let initializedAttributes = posix_spawnattr_init(&attributes)
        guard initializedAttributes == 0 else { throw InteractiveFailure.capturedSpawn(initializedAttributes) }
        defer { posix_spawnattr_destroy(&attributes) }

        let setGroup = posix_spawnattr_setpgroup(&attributes, 0)
        guard setGroup == 0 else { throw InteractiveFailure.capturedSpawn(setGroup) }
        let setFlags = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )
        guard setFlags == 0 else { throw InteractiveFailure.capturedSpawn(setFlags) }
        if let directory = request.currentDirectory {
            let chdir = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
            guard chdir == 0 else { throw InteractiveFailure.capturedSpawn(chdir) }
        }
        let dupIn = posix_spawn_file_actions_adddup2(
            &actions,
            stdin.fileHandleForReading.fileDescriptor,
            STDIN_FILENO
        )
        guard dupIn == 0 else { throw InteractiveFailure.capturedSpawn(dupIn) }
        let dupOut = posix_spawn_file_actions_adddup2(
            &actions,
            stdout.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        )
        guard dupOut == 0 else { throw InteractiveFailure.capturedSpawn(dupOut) }
        let openErr = posix_spawn_file_actions_addopen(
            &actions,
            STDERR_FILENO,
            "/dev/null",
            O_WRONLY,
            0
        )
        guard openErr == 0 else { throw InteractiveFailure.capturedSpawn(openErr) }

        var argv = ([request.executable.path] + request.arguments).map { strdup($0) }
        var envp = request.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.compactMap { $0 }.forEach { free($0) }
            envp.compactMap { $0 }.forEach { free($0) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw InteractiveFailure.capturedSpawn(ENOMEM)
        }
        argv.append(nil)
        envp.append(nil)

        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { env in
                guard let argBase = args.baseAddress, let envBase = env.baseAddress else {
                    return Int32(ENOMEM)
                }
                return posix_spawn(
                    &pid,
                    request.executable.path,
                    &actions,
                    &attributes,
                    argBase,
                    envBase
                )
            }
        }
        guard spawned == 0, pid > 1, pid != getpid() else {
            throw InteractiveFailure.capturedSpawn(spawned == 0 ? EIO : spawned)
        }
#if DEBUG
        OnboardingBoundaryObserver.note(.cli)
#endif

        // Keep only the parent ends. CLOEXEC ensures that the child did not
        // inherit any duplicate parent descriptors.
        do {
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
        } catch {
            stopProcessGroup(pid, grace: 0)
            reapProcess(pid)
            throw InteractiveFailure.capturedIO()
        }
        let session = InteractiveSession(
            pid: pid,
            input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading,
            timeout: request.timeout,
            maximumInputBytes: request.maximumInputBytes,
            maximumOutputBytes: request.maximumOutputBytes,
            terminationGrace: request.terminationGrace,
            isCancelled: request.isCancelled
        )
        transferred = true
        return session
    }
}
