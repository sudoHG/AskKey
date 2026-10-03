import Foundation
import CoreFoundation
import AskKeyBroker

enum HelperError: Error, LocalizedError {
    case usage
    case approvalRequired

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: askkey health | version | status | mcp | open | run --credential <name> [--credential <name> ...] [--wait-for-approval] [--operation-id <id>] [--caller-name <name>] [--caller-purpose <purpose>] -- <command> [args...]"
        case .approvalRequired:
            return "Ask Key approval is required. Retry with the same --operation-id after approval."
        }
    }
}
