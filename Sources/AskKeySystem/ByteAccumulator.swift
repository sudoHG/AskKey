import Foundation
import Darwin

final class ByteAccumulator {
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
