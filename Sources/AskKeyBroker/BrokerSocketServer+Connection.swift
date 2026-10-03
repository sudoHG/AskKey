import Foundation
import Darwin

extension BrokerSocketServer {
    func serve(_ fd: Int32) {
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

    func write(_ response: BrokerResponse, to fd: Int32) -> Bool {
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
}
