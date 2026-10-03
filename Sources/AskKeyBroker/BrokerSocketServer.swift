import Foundation
import Darwin

public final class BrokerSocketServer {
    private let socketPath: String
    let handler: BrokerRequestHandler
    let failedReadBufferCleared: @Sendable (BrokerClearedReadBuffer) -> Void
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var activeConnections = 0
    private var activeRequests = 0
    private let acceptQueue = DispatchQueue(label: "com.sudohg.askkey.broker.accept")
    private let connectionQueue = DispatchQueue(label: "com.sudohg.askkey.broker.connection", attributes: .concurrent)
    let requestQueue = DispatchQueue(label: "com.sudohg.askkey.broker.request", attributes: .concurrent)

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

    func reserveRequest() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard activeRequests < BrokerLimits.maximumConcurrentRequests else { return false }
        activeRequests += 1
        return true
    }

    func releaseRequest() {
        stateLock.lock(); defer { stateLock.unlock() }
        activeRequests -= 1
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
