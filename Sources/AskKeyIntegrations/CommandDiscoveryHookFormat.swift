import Darwin
import Foundation

public enum CommandDiscoveryHookFormat: String, Equatable, Sendable {
    case cursorMerged
    case grokOwned
    case claudeMerged

    var name: String {
        switch self {
        case .cursorMerged: return "Cursor"
        case .grokOwned: return "Grok"
        case .claudeMerged: return "Claude Code"
        }
    }

    var invocationMarker: String {
        switch self {
        case .cursorMerged: return "hook cursor"
        case .grokOwned: return "hook grok"
        case .claudeMerged: return "hook claude"
        }
    }
}
