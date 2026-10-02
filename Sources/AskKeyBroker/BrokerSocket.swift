import Foundation
import AskKeyBrokerC
#if canImport(Darwin)
import Darwin
#endif

public enum BrokerSocketError: Error, LocalizedError, Equatable {
    case pathTooLong
    case notRunning
    case noResponse
    case frameTooLarge
    case responseTooLarge
    case malformedResponse
    case brokerFailure(BrokerErrorCode)
    case systemError(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong: return "The Broker socket path is too long."
        case .notRunning: return "The Ask Key Broker is not running."
        case .noResponse: return "The Ask Key Broker closed the connection without responding."
        case .frameTooLarge: return "The Broker request exceeds its fixed size limit."
        case .responseTooLarge: return "The Broker response exceeds its fixed size limit."
        case .malformedResponse: return "The Ask Key Broker returned a malformed response."
        case .brokerFailure(let code): return "The Ask Key Broker rejected the request (\(code.rawValue))."
        case let .systemError(call, code): return "Socket \(call) failed (errno \(code))."
        }
    }
}

enum BrokerClearedReadFailure: Equatable, Sendable {
    case deadline
    case endOfFile
    case pollError(Int32)
    case readError(Int32)
}

struct BrokerClearedReadBuffer: Sendable {
    let buffer: Data
    let bytesRead: Int
    let failure: BrokerClearedReadFailure
}

public final class BrokerSocketServer {
    private let socketPath: String
    private let handler: BrokerRequestHandler
    private let failedReadBufferCleared: @Sendable (BrokerClearedReadBuffer) -> Void
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var activeConnections = 0
    private var activeRequests = 0
    private let acceptQueue = DispatchQueue(label: "com.sudohg.askkey.broker.accept")
    private let connectionQueue = DispatchQueue(label: "com.sudohg.askkey.broker.connection", attributes: .concurrent)
    private let requestQueue = DispatchQueue(label: "com.sudohg.askkey.broker.request", attributes: .concurrent)

    public init(socketPath: String, handler: BrokerRequestHandler) {
        self.socketPath = socketPath
        self.handler = handler
        failedReadBufferCleared = { _ in }
    }

    init(
        socketPath: String,
        handler: BrokerRequestHandler,
        failedReadBufferCleared: @escaping @Sendable (BrokerClearedReadBuffer) -> Void
    ) {
        self.socketPath = socketPath
        self.handler = handler
        self.failedReadBufferCleared = failedReadBufferCleared
    }

    public func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        do {
            var address = try makeBrokerAddress(path: socketPath)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw BrokerSocketError.systemError("bind", errno) }
            guard chmod(socketPath, 0o600) == 0 else {
                throw BrokerSocketError.systemError("chmod", errno)
            }
            guard listen(fd, Int32(BrokerLimits.maximumQueuedRequests)) == 0 else {
                throw BrokerSocketError.systemError("listen", errno)
            }
        } catch {
            close(fd)
            unlink(socketPath)
            throw error
        }

        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning {
            let fd = accept(currentListenFD, nil, nil)
            guard fd >= 0 else {
                if !isRunning { return }
                continue
            }
            do {
                try BrokerSocketIO.configure(fd: fd)
            } catch {
                NSLog("Ask Key Broker rejected a socket whose safety limits could not be configured: \(error.localizedDescription)")
                close(fd)
                continue
            }
            guard reserveConnection() else {
                _ = write(.failure(.resourceExhausted), to: fd)
                close(fd)
                continue
            }
            connectionQueue.async { [weak self] in
                guard let self else { close(fd); return }
                self.serve(fd)
                self.releaseConnection()
            }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        for _ in 0..<BrokerLimits.maximumRequestsPerConnection {
            switch BrokerSocketIO.readFrameWithDescriptors(
                fd: fd,
                maximumBytes: BrokerLimits.maximumFrameBytes,
                failedReadBufferCleared: failedReadBufferCleared
            ) {
            case .end:
                return
            case .failure(let error):
                let code: BrokerErrorCode = error == .tooLarge ? .resourceExhausted : .deadlineExceeded
                _ = write(.failure(code), to: fd)
                return
            case .success(let frame):
                var data = frame.data
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                defer { frame.descriptors.forEach { close($0) } }
                guard reserveRequest() else {
                    _ = write(.failure(.resourceExhausted), to: fd)
                    return
                }
                guard let request = BrokerRequest.decodeClearingFrame(&data) else {
                    releaseRequest()
                    guard write(.failure(.invalidRequest), to: fd) else { return }
                    continue
                }
                let descriptors: BrokerPassedFileDescriptors?
                if frame.descriptors.isEmpty {
                    descriptors = nil
                } else if request.method == "runtime.run", frame.descriptors.count == 4 {
                    descriptors = .init(
                        standardInput: frame.descriptors[0],
                        standardOutput: frame.descriptors[1],
                        standardError: frame.descriptors[2],
                        control: frame.descriptors[3]
                    )
                } else {
                    releaseRequest()
                    guard write(.failure(.invalidRequest), to: fd) else { return }
                    continue
                }
                let response = execute(
                    request,
                    descriptors: descriptors,
                    connectionFD: fd,
                    hasRequestDeadline: request.method != "runtime.run"
                )
                guard write(response, to: fd) else {
                    handler.cancelUndelivered(request, response: response)
                    return
                }
            }
        }
        _ = write(.failure(.resourceExhausted), to: fd)
    }

    private func execute(
        _ request: BrokerRequest,
        descriptors: BrokerPassedFileDescriptors?,
        connectionFD: Int32,
        hasRequestDeadline: Bool
    ) -> BrokerResponse {
        let completed = DispatchSemaphore(value: 0)
        let box = BrokerResponseBox()
        let lease = BrokerRequestLease { [weak self] in self?.releaseRequest() }
        let cancellation = BrokerCancellation()
        let disconnectQueue = DispatchQueue(label: "com.sudohg.askkey.runtime-disconnect")
        let disconnectSource: DispatchSourceRead? = hasRequestDeadline ? nil : {
            let source = DispatchSource.makeReadSource(
                fileDescriptor: connectionFD,
                queue: disconnectQueue
            )
            source.setEventHandler {
                var byte: UInt8 = 0
                let received = recv(connectionFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if received >= 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    cancellation.cancel()
                    source.cancel()
                }
            }
            source.resume()
            return source
        }()
        defer {
            disconnectSource?.cancel()
            disconnectQueue.sync {}
        }
        requestQueue.async { [weak self] in
            guard let self else { completed.signal(); return }
            box.set(self.handler.handle(request, descriptors: descriptors, cancellation: cancellation))
            lease.release()
            completed.signal()
        }
        let waitResult = hasRequestDeadline
            ? completed.wait(timeout: .now() + BrokerLimits.requestDeadline)
            : completed.wait(timeout: .distantFuture)
        guard waitResult == .success else {
            cancellation.cancel()
            lease.release()
            return .failure(.deadlineExceeded)
        }
        return box.get() ?? .failure(.internalError)
    }

    private func write(_ response: BrokerResponse, to fd: Int32) -> Bool {
        guard let encoded = try? JSONEncoder().encode(response) else { return false }
        let bounded: Data
        if encoded.count <= BrokerLimits.maximumResponseBytes {
            bounded = encoded
        } else {
            guard let fallback = try? JSONEncoder().encode(BrokerResponse.failure(.responseTooLarge)) else {
                return false
            }
            bounded = fallback
        }
        return BrokerSocketIO.writeFrame(fd: fd, data: bounded)
    }

    private var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private var currentListenFD: Int32 {
        stateLock.lock(); defer { stateLock.unlock() }
        return listenFD
    }

    private func reserveConnection() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard activeConnections < BrokerLimits.maximumConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        stateLock.lock(); defer { stateLock.unlock() }
        activeConnections -= 1
    }

    private func reserveRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard activeRequests < BrokerLimits.maximumConcurrentRequests else { return false }
        activeRequests += 1
        return true
    }

    private func releaseRequest() {
        stateLock.lock(); defer { stateLock.unlock() }
        activeRequests -= 1
    }
}

// Safe: the release flag is lock-guarded and the callback is immutable.
private final class BrokerRequestLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private let releaseImpl: () -> Void

    init(release: @escaping () -> Void) {
        releaseImpl = release
    }

    func release() {
        lock.lock()
        guard !isReleased else { lock.unlock(); return }
        isReleased = true
        lock.unlock()
        releaseImpl()
    }
}

private final class BrokerResponseBox {
    private let lock = NSLock()
    private var value: BrokerResponse?

    func set(_ response: BrokerResponse) {
        lock.lock(); defer { lock.unlock() }
        value = response
    }

    func get() -> BrokerResponse? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

public final class BrokerSocketClient {
    private let socketPath: String
    private let beforeRuntimeRequestWrite: @Sendable (Int32, Int32) -> Void

    public init(socketPath: String) {
        self.socketPath = socketPath
        beforeRuntimeRequestWrite = { _, _ in }
    }

    init(
        socketPath: String,
        beforeRuntimeRequestWrite: @escaping @Sendable (Int32, Int32) -> Void
    ) {
        self.socketPath = socketPath
        self.beforeRuntimeRequestWrite = beforeRuntimeRequestWrite
    }

    public func send(
        _ request: BrokerRequest,
        signalSession: BrokerSignalSession? = nil
    ) throws -> BrokerResponse {
        var encoded = try JSONEncoder().encode(request)
        defer { encoded.resetBytes(in: encoded.startIndex..<encoded.endIndex) }
        guard encoded.count <= BrokerLimits.maximumFrameBytes else { throw BrokerSocketError.frameTooLarge }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        defer { close(fd) }
        try BrokerSocketIO.configure(fd: fd)

        var address = try makeBrokerAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw BrokerSocketError.notRunning }
        try signalSession?.attachRequest(socketFD: fd)
        defer { signalSession?.detach() }
        guard BrokerSocketIO.writeFrame(fd: fd, data: encoded) else {
            throw BrokerSocketError.systemError("write", errno)
        }
        switch BrokerSocketIO.readFrame(fd: fd, maximumBytes: BrokerLimits.maximumResponseBytes) {
        case .end:
            throw BrokerSocketError.noResponse
        case .failure(.tooLarge):
            throw BrokerSocketError.responseTooLarge
        case .failure:
            throw BrokerSocketError.noResponse
        case .success(let data):
            guard let response = try? JSONDecoder().decode(BrokerResponse.self, from: data) else {
                throw BrokerSocketError.malformedResponse
            }
            return response
        }
    }

    public func run(
        _ request: BrokerTextRunRequest,
        standardInputFD: Int32 = FileHandle.standardInput.fileDescriptor,
        standardOutputFD: Int32 = FileHandle.standardOutput.fileDescriptor,
        standardErrorFD: Int32 = FileHandle.standardError.fileDescriptor,
        forwardSignals: Bool = false,
        signalSession: BrokerSignalSession? = nil
    ) throws -> BrokerTextRunResult {
        let brokerRequest = BrokerRequest(
            version: BrokerProtocolVersion.current,
            method: "runtime.run",
            textRun: request
        )
        let encoded = try JSONEncoder().encode(brokerRequest)
        guard encoded.count <= BrokerLimits.maximumFrameBytes else { throw BrokerSocketError.frameTooLarge }
        let ownedSignals = forwardSignals && signalSession == nil ? BrokerSignalSession() : nil
        let signals = signalSession ?? ownedSignals
        defer { ownedSignals?.stop() }
        let fd = try connectSocket()
        defer { close(fd) }
        var controlPipe: [Int32] = [-1, -1]
        guard pipe(&controlPipe) == 0 else { throw BrokerSocketError.systemError("pipe", errno) }
        defer {
            if controlPipe[0] >= 0 { close(controlPipe[0]) }
            if controlPipe[1] >= 0 { close(controlPipe[1]) }
        }
        try signals?.attachRuntime(controlFD: controlPipe[1], socketFD: fd)
        defer { signals?.detach() }
        beforeRuntimeRequestWrite(controlPipe[0], fd)
        let descriptors = [standardInputFD, standardOutputFD, standardErrorFD, controlPipe[0]]
        if let signals {
            let writeResult = try BrokerSocketIO.writeFrame(
                fd: fd, data: encoded, descriptors: descriptors, signalSession: signals
            )
            switch writeResult {
            case .sent: break
            case .failed: throw BrokerSocketError.systemError("sendmsg", errno)
            case .outcomeUnknown: return .outcomeUnknown
            }
        } else {
            guard BrokerSocketIO.writeFrame(fd: fd, data: encoded, descriptors: descriptors) else {
                throw BrokerSocketError.systemError("sendmsg", errno)
            }
        }
        close(controlPipe[0])
        controlPipe[0] = -1
        do {
            try BrokerSocketIO.configureBlockingRuntimeResponse(fd: fd)
        } catch {
            return .outcomeUnknown
        }
        switch BrokerSocketIO.readFrameBlocking(fd: fd, maximumBytes: BrokerLimits.maximumResponseBytes) {
        case .success(let data):
            guard let response = try? JSONDecoder().decode(BrokerResponse.self, from: data) else {
                throw BrokerSocketError.malformedResponse
            }
            switch response {
            case .success(.textRun(let result)): return result
            case .failure(let code): throw BrokerSocketError.brokerFailure(code)
            default: throw BrokerSocketError.malformedResponse
            }
        case .end: return .outcomeUnknown
        case .failure(.tooLarge): throw BrokerSocketError.responseTooLarge
        case .failure: return .outcomeUnknown
        }
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        do {
            try BrokerSocketIO.configure(fd: fd)
            var address = try makeBrokerAddress(path: socketPath)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw BrokerSocketError.notRunning }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

}

/// A single caller retains this session across sequential runtime and approval
/// status requests. Signals remain latched between connections; an active
/// runtime still receives them through its existing control pipe.
public final class BrokerSignalSession {
    private let sources: [(Int32, sig_t?, DispatchSourceSignal)]
    private let queue: DispatchQueue
    private let permit: BrokerSignalPermit
    private let state: BrokerSignalState

    public init() {
        permit = BrokerSignalPermit()
        let signalState = BrokerSignalState()
        state = signalState
        let forwardingQueue = DispatchQueue(label: "com.sudohg.askkey.signal-forwarding")
        queue = forwardingQueue
        sources = ([SIGINT, SIGTERM] as [Int32]).map { signalNumber in
            let previous = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: forwardingQueue)
            source.setEventHandler {
                signalState.receive(signalNumber)
            }
            source.resume()
            return (signalNumber, previous, source)
        }
    }

    deinit { stop() }

    public func checkCancellation() throws {
        try queue.sync { try state.checkCancellation() }
    }

    public func waitUnlessCancelled(for interval: TimeInterval) throws {
        try checkCancellation()
        _ = state.receivedSignal.wait(timeout: .now() + interval)
        try checkCancellation()
    }

    public var isCancelled: Bool { state.cancellation.isCancelled }

    public func stop() {
        let shouldStop = queue.sync {
            guard !state.stopped else { return false }
            state.stopped = true
            state.connection = nil
            return true
        }
        guard shouldStop else { return }
        for (signalNumber, previous, source) in sources {
            source.cancel()
            queue.sync {}
            _ = signal(signalNumber, previous)
        }
        permit.release()
    }

    fileprivate func attachRuntime(controlFD: Int32, socketFD: Int32) throws {
        try attach(.runtime(controlFD: controlFD, socketFD: socketFD))
    }

    fileprivate func attachRequest(socketFD: Int32) throws {
        try attach(.request(socketFD: socketFD))
    }

    private func attach(_ connection: BrokerSignalState.Connection) throws {
        try queue.sync {
            // Attachment is ordered with signal handling, so a cancellation
            // already recorded by this session cannot start another request.
            // Once attached, runtime control retains its existing boundary.
            try state.checkCancellation()
            guard state.connection == nil else {
                throw BrokerSocketError.systemError("signal-session", EBUSY)
            }
            state.connection = connection
        }
    }

    fileprivate func detach() {
        // Drain forwarding work before the caller closes or reuses its FDs.
        queue.sync { state.connection = nil }
    }

    fileprivate func performWrite<T>(_ write: () -> T) throws -> T {
        try queue.sync {
            try state.checkCancellation()
            return write()
        }
    }
}

// Connection and stopped are accessed only on the session's serial queue.
private final class BrokerSignalState: @unchecked Sendable {
    enum Connection {
        case runtime(controlFD: Int32, socketFD: Int32)
        case request(socketFD: Int32)
    }

    let cancellation = BrokerCancellation()
    let receivedSignal = DispatchSemaphore(value: 0)
    var connection: Connection?
    var stopped = false

    func checkCancellation() throws {
        guard !stopped else { throw BrokerCancellationError.cancelled }
        try cancellation.check()
    }

    func receive(_ signalNumber: Int32) {
        guard !stopped else { return }
        cancellation.cancel()
        receivedSignal.signal()
        switch connection {
        case .runtime(let controlFD, let socketFD):
            var value = UInt8(signalNumber)
            if write(controlFD, &value, 1) != 1 {
                _ = shutdown(socketFD, SHUT_RDWR)
            }
        case .request(let socketFD):
            // A status query owns no target process; interrupt its blocking IO.
            _ = shutdown(socketFD, SHUT_RDWR)
        case nil:
            break
        }
    }
}

private final class BrokerSignalPermit {
    private static let lock = NSLock()
    private let stateLock = NSLock()
    private var released = false

    init() { Self.lock.lock() }

    func release() {
        stateLock.lock()
        guard !released else { stateLock.unlock(); return }
        released = true
        stateLock.unlock()
        Self.lock.unlock()
    }
}

extension BrokerRequest {
    static func decodeClearingFrame(_ frame: inout Data) -> BrokerRequest? {
        defer { frame.resetBytes(in: frame.startIndex..<frame.endIndex) }
        return try? JSONDecoder().decode(BrokerRequest.self, from: frame)
    }
}

extension BrokerSocketServer {
    static func exercisePartialReadErrorForTesting(
        partial: Data,
        declaredLength: Int,
        errorCode: Int32,
        failedReadBufferCleared: @escaping @Sendable (BrokerClearedReadBuffer) -> Void
    ) {
        BrokerSocketIO.exercisePartialReadErrorForTesting(
            partial: partial,
            declaredLength: declaredLength,
            errorCode: errorCode,
            failedReadBufferCleared: failedReadBufferCleared
        )
    }
}

private func makeBrokerAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw BrokerSocketError.pathTooLong }
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
        path.withCString { strncpy(destination, $0, capacity - 1) }
    }
    return address
}

private enum BrokerFrameFailure: Equatable {
    case tooLarge
    case incompleteOrTimedOut
}

private enum BrokerFrameRead {
    case success(Data)
    case failure(BrokerFrameFailure)
    case end
}

private struct BrokerFrameWithDescriptors {
    let data: Data
    let descriptors: [Int32]
}

private enum BrokerFrameWithDescriptorsRead {
    case success(BrokerFrameWithDescriptors)
    case failure(BrokerFrameFailure)
    case end
}

private enum BrokerSocketIO {
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
