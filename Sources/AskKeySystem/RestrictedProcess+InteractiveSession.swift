import Foundation
import Darwin

extension RestrictedProcess {

    /// A synchronous JSONL transport. Callers own one session on one thread.
    package final class InteractiveSession: @unchecked Sendable {
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

        package func writeLine(_ data: Data) throws {
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

        package func readLine() throws -> Data {
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

        package func close() {
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
}
