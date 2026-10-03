import Foundation
import AskKeyBrokerC
#if canImport(Darwin)
import Darwin
#endif

func makeBrokerAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw BrokerSocketError.pathTooLong }
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
        path.withCString { strncpy(destination, $0, capacity - 1) }
    }
    return address
}

enum BrokerSocketIO {
    enum RuntimeWriteResult {
        case sent
        case failed
        case outcomeUnknown
    }

    static func configure(fd: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0 else {
            throw BrokerSocketError.systemError("setsockopt(SO_NOSIGPIPE)", errno)
        }
        var readTimeout = timeval(tv_sec: Int(BrokerLimits.readDeadline), tv_usec: 0)
        var writeTimeout = timeval(tv_sec: Int(BrokerLimits.writeDeadline), tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout.size(ofValue: readTimeout))) == 0 else {
            throw BrokerSocketError.systemError("setsockopt(SO_RCVTIMEO)", errno)
        }
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout.size(ofValue: writeTimeout))) == 0 else {
            throw BrokerSocketError.systemError("setsockopt(SO_SNDTIMEO)", errno)
        }
    }

    static func configureBlockingRuntimeResponse(fd: Int32) throws {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw BrokerSocketError.systemError("setsockopt(SO_RCVTIMEO)", errno)
        }
    }

    static func readFrameWithDescriptors(
        fd: Int32,
        maximumBytes: Int,
        failedReadBufferCleared: @Sendable (BrokerClearedReadBuffer) -> Void = { _ in }
    ) -> BrokerFrameWithDescriptorsRead {
        var header = [UInt8](repeating: 0, count: 4)
        var descriptors = [Int32](repeating: -1, count: 4)
        var descriptorCount = 0
        let received = askkey_receive_header_with_fds(
            fd, &header, header.count, &descriptors, descriptors.count, &descriptorCount
        )
        descriptors = Array(descriptors.prefix(descriptorCount))
        if received == 0 { return .end }
        guard received == 4 else {
            descriptors.forEach { close($0) }
            return .failure(.incompleteOrTimedOut)
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumBytes) else {
            descriptors.forEach { close($0) }
            return .failure(.tooLarge)
        }
        guard length > 0 else {
            descriptors.forEach { close($0) }
            return .failure(.incompleteOrTimedOut)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(BrokerLimits.readDeadline * 1_000_000_000)
        switch readExact(
            fd: fd,
            count: Int(length),
            deadline: deadline,
            failedReadBufferCleared: failedReadBufferCleared
        ) {
        case .success(let data): return .success(.init(data: data, descriptors: descriptors))
        case .end, .failure:
            descriptors.forEach { close($0) }
            return .failure(.incompleteOrTimedOut)
        }
    }

    static func readFrame(
        fd: Int32,
        maximumBytes: Int,
        failedReadBufferCleared: @Sendable (BrokerClearedReadBuffer) -> Void = { _ in }
    ) -> BrokerFrameRead {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(BrokerLimits.readDeadline * 1_000_000_000)
        switch readExact(
            fd: fd,
            count: 4,
            deadline: deadline,
            failedReadBufferCleared: failedReadBufferCleared
        ) {
        case .end: return .end
        case .failure: return .failure(.incompleteOrTimedOut)
        case .success(let header):
            let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= UInt32(maximumBytes) else { return .failure(.tooLarge) }
            guard length > 0 else { return .failure(.incompleteOrTimedOut) }
            switch readExact(
                fd: fd,
                count: Int(length),
                deadline: deadline,
                failedReadBufferCleared: failedReadBufferCleared
            ) {
            case .success(let data): return .success(data)
            case .end, .failure: return .failure(.incompleteOrTimedOut)
            }
        }
    }

    static func writeFrame(fd: Int32, data: Data) -> Bool {
        guard data.count <= Int(UInt32.max) else { return false }
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        frame.append(data)
        return writeAll(fd: fd, data: frame)
    }

    static func writeFrame(fd: Int32, data: Data, descriptors: [Int32]) -> Bool {
        guard data.count <= Int(UInt32.max), descriptors.count == 4 else { return false }
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        frame.append(data)
        return frame.withUnsafeBytes { bytes in
            descriptors.withUnsafeBufferPointer { fds in
                askkey_send_with_fds(fd, bytes.baseAddress, bytes.count, fds.baseAddress, fds.count)
                    == bytes.count
            }
        }
    }

    static func writeFrame(
        fd: Int32,
        data: Data,
        descriptors: [Int32],
        signalSession: BrokerSignalSession
    ) throws -> RuntimeWriteResult {
        guard data.count <= Int(UInt32.max), descriptors.count == 4 else { return .failed }
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            return .failed
        }
        var needsRestore = true
        defer { if needsRestore { _ = fcntl(fd, F_SETFL, originalFlags) } }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(BrokerLimits.writeDeadline * 1_000_000_000)
        var length = UInt32(data.count).bigEndian
        // Each actual write is ordered with cancellation. Only nonblocking
        // syscalls run on the signal queue; a slow peer cannot hold that queue
        // across a whole frame. A failed partial header closes the connection.
        let header = try signalSession.performWrite {
            let count = withUnsafeBytes(of: &length) { bytes in
                descriptors.withUnsafeBufferPointer { fds in
                    askkey_send_with_fds(fd, bytes.baseAddress, bytes.count, fds.baseAddress, fds.count)
                }
            }
            return (count, errno)
        }
        guard header.0 == MemoryLayout<UInt32>.size else {
            errno = header.1
            return .failed
        }
        let sent = try data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { errno = ETIMEDOUT; return false }
                let attempt = try signalSession.performWrite {
                    let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                    return (count, errno)
                }
                if attempt.0 > 0 {
                    offset += attempt.0
                    continue
                }
                if attempt.0 < 0, attempt.1 == EINTR { continue }
                guard attempt.0 < 0, attempt.1 == EAGAIN || attempt.1 == EWOULDBLOCK else {
                    errno = attempt.1
                    return false
                }
                // Readiness waits happen outside the signal queue and use one
                // absolute frame deadline, rather than a fresh per-write wait.
                let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
                let milliseconds = Int32(min(50, (remaining + 999_999) / 1_000_000))
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, milliseconds)
                if ready < 0, errno != EINTR { return false }
            }
            return true
        }
        guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
            // A complete frame may already have started a target. Failure to
            // restore response IO cannot turn that into a retryable send error.
            return sent ? .outcomeUnknown : .failed
        }
        needsRestore = false
        return sent ? .sent : .failed
    }

    static func readFrameBlocking(fd: Int32, maximumBytes: Int) -> BrokerFrameRead {
        func exact(_ count: Int) -> Data? {
            var data = Data(count: count)
            var offset = 0
            let okay = data.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                while offset < count {
                    let received = read(fd, base.advanced(by: offset), count - offset)
                    if received < 0, errno == EINTR { continue }
                    guard received > 0 else { return false }
                    offset += received
                }
                return true
            }
            return okay ? data : nil
        }
        guard let header = exact(4) else { return .end }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(maximumBytes) else { return .failure(.tooLarge) }
        guard length > 0, let body = exact(Int(length)) else { return .failure(.incompleteOrTimedOut) }
        return .success(body)
    }
    private static func readExact(
        fd: Int32,
        count: Int,
        deadline: UInt64,
        failedReadBufferCleared: @Sendable (BrokerClearedReadBuffer) -> Void,
        skipReadinessCheck: Bool = false,
        readBytes: (Int32, UnsafeMutableRawPointer, Int) -> Int = { read($0, $1, $2) }
    ) -> BrokerFrameRead {
        var data = Data(count: count)
        var offset = 0
        var failure: BrokerClearedReadFailure?
        let result = data.withUnsafeMutableBytes { raw -> BrokerFrameFailure? in
            guard let base = raw.baseAddress else {
                failure = .readError(EFAULT)
                return .incompleteOrTimedOut
            }
            while offset < count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else {
                    failure = .deadline
                    return .incompleteOrTimedOut
                }
                if !skipReadinessCheck {
                    let remainingMilliseconds = Int32(min(
                        (deadline - now + 999_999) / 1_000_000,
                        UInt64(Int32.max)
                    ))
                    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, remainingMilliseconds)
                    if ready < 0, errno == EINTR { continue }
                    if ready < 0 {
                        failure = .pollError(errno)
                        return .incompleteOrTimedOut
                    }
                    guard ready > 0 else {
                        failure = .deadline
                        return .incompleteOrTimedOut
                    }
                    guard descriptor.revents & Int16(POLLIN) != 0 else {
                        failure = descriptor.revents & Int16(POLLHUP) != 0
                            ? .endOfFile
                            : .pollError(Int32(descriptor.revents))
                        return .incompleteOrTimedOut
                    }
                }
                let received = readBytes(fd, base.advanced(by: offset), count - offset)
                if received == 0 {
                    failure = .endOfFile
                    return .incompleteOrTimedOut
                }
                if received < 0 {
                    if errno == EINTR { continue }
                    failure = .readError(errno)
                    return .incompleteOrTimedOut
                }
                offset += received
            }
            return nil
        }
        if let result {
            let bytesRead = offset
            data.resetBytes(in: data.startIndex..<data.endIndex)
            failedReadBufferCleared(.init(
                buffer: data,
                bytesRead: bytesRead,
                failure: failure ?? .readError(EIO)
            ))
            return .failure(result)
        }
        return .success(data)
    }

    static func exercisePartialReadErrorForTesting(
        partial: Data,
        declaredLength: Int,
        errorCode: Int32,
        failedReadBufferCleared: @escaping @Sendable (BrokerClearedReadBuffer) -> Void
    ) {
        var deliveredPartial = false
        _ = readExact(
            fd: -1,
            count: declaredLength,
            deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000,
            failedReadBufferCleared: failedReadBufferCleared,
            skipReadinessCheck: true,
            readBytes: { _, destination, maximumCount in
                if !deliveredPartial {
                    let bytesToCopy = min(partial.count, maximumCount)
                    partial.withUnsafeBytes { source in
                        if let baseAddress = source.baseAddress {
                            memcpy(destination, baseAddress, bytesToCopy)
                        }
                    }
                    deliveredPartial = true
                    return bytesToCopy
                }
                errno = errorCode
                return -1
            }
        )
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }
}
