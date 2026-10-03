import Foundation
import CoreFoundation
import AskKeyBroker

enum MCPFrameRead {
    case frame(Data)
    case tooLarge
    case end
    case failure(Int32)
}

func readMCPFrame(maximumBytes: Int) -> MCPFrameRead {
    var frame = Data()
    var oversized = false
    while true {
        var byte: UInt8 = 0
        let count = read(FileHandle.standardInput.fileDescriptor, &byte, 1)
        if count < 0, errno == EINTR { continue }
        if count < 0 { return .failure(errno) }
        if count == 0 {
            if oversized { return .tooLarge }
            return frame.isEmpty ? .end : .frame(frame)
        }
        if byte == 0x0A { return oversized ? .tooLarge : .frame(frame) }
        if frame.count >= maximumBytes {
            oversized = true
        } else if !oversized {
            frame.append(byte)
        }
    }
}

func writeMCPResponse(_ response: [String: Any]) throws {
    var output = try JSONSerialization.data(withJSONObject: response)
    output.append(0x0A)
    try FileHandle.standardOutput.write(contentsOf: output)
}
