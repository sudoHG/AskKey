import Foundation
import Darwin

func drain(
    stdout: Int32,
    stderr: Int32?,
    buffer: inout [UInt8],
    stdoutAcc: ByteAccumulator,
    stderrAcc: ByteAccumulator,
    truncate: Bool
) throws -> Bool {
    var readAny = false
    let pipes: [(Int32, ByteAccumulator)]
    if let stderr {
        pipes = [(stdout, stdoutAcc), (stderr, stderrAcc)]
    } else {
        pipes = [(stdout, stdoutAcc)]
    }
    for (descriptor, accumulator) in pipes {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(descriptor, base, raw.count)
        }
        if count > 0, count <= buffer.count {
            readAny = true
            try accumulator.append(Data(buffer[0..<count]), truncate: truncate)
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw RestrictedProcess.Failure.capturedIO()
        }
    }
    return readAny
}
