import Foundation
import Darwin

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
