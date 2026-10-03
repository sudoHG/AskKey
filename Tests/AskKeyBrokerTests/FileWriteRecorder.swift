@testable import AskKeyBroker
import Foundation
import Darwin

final class FileWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    var receivedBytes: Data {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func handle(_ request: BrokerFileWriteRequest) throws -> BrokerFileWritePayload {
        lock.lock(); defer { lock.unlock() }
        switch request {
        case .beginComponent, .freezeComponent, .cancelUpload:
            throw BrokerFileWriteError.invalidRequest
        case .begin(let begin):
            guard begin.operationID == "write-operation",
                  begin.credentialID == "credential-id",
                  begin.targetID == "credential-id",
                  begin.operation == .modify,
                  begin.originalFilename == "AuthKey.p8",
                  begin.expectedByteCount == 17 else {
                throw BrokerFileWriteError.invalidRequest
            }
            return .upload(.init(uploadID: "upload-id", capability: "upload-capability"))
        case .append(let append):
            guard append.uploadID == "upload-id",
                  append.capability == "upload-capability",
                  append.offset == bytes.count else {
                throw BrokerFileWriteError.invalidRequest
            }
            bytes.append(append.bytes)
            return .chunkAccepted(nextOffset: bytes.count)
        case .freeze(let freeze):
            guard freeze.uploadID == "upload-id",
                  freeze.capability == "upload-capability",
                  bytes == Data("file-write-secret".utf8) else {
                throw BrokerFileWriteError.invalidRequest
            }
            return .approval(.init(
                requestID: "approval-id",
                capability: "approval-capability",
                state: .pending,
                retryCount: 0
            ))
        }
    }
}
