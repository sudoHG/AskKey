import Foundation
import Darwin

extension RestrictedProcess {
    package static func run(_ request: Request) throws -> Result {
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
        RuntimeOperationEvents.publish(.cli)

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
private func now(monotonic: Bool) -> TimeInterval {
    monotonic
        ? ProcessInfo.processInfo.systemUptime
        : Date().timeIntervalSinceReferenceDate
}
