import Foundation
import CoreFoundation
import AskKeyBroker

enum ExpectedFileWriteResponse: String {
    case upload
    case chunk
    case approval
    case component
    case cancelled

    func matches(_ payload: BrokerFileWritePayload) -> Bool {
        switch (self, payload) {
        case (.upload, .upload), (.chunk, .chunkAccepted), (.approval, .approval),
             (.component, .componentFrozen), (.cancelled, .uploadCancelled): return true
        default: return false
        }
    }
}
