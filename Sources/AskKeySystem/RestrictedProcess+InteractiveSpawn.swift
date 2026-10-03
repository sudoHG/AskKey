import Foundation
import Darwin

extension RestrictedProcess {
    package static func startInteractive(_ request: InteractiveRequest) throws -> InteractiveSession {
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
        RuntimeOperationEvents.publish(.cli)

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
