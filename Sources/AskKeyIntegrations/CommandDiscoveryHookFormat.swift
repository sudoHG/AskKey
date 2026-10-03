import Darwin
import Foundation

public enum CommandDiscoveryHookFormat: String, Equatable, Sendable {
    case cursorMerged
    case grokOwned

    var name: String {
        switch self {
        case .cursorMerged: return "Cursor"
        case .grokOwned: return "Grok"
        }
    }

    var invocationMarker: String {
        switch self {
        case .cursorMerged: return "hook cursor"
        case .grokOwned: return "hook grok"
        }
    }
}
