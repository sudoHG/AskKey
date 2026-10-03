import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

extension CursorUserMCPAdapter {
    /// Presence includes stale or incomplete entries that still need repair.
    public func hasConfiguration() throws -> Bool {
        let object = try loadExistingObject()
        return (object?["mcpServers"] as? [String: Any])?["askkey"] != nil
    }

    public func preview() throws -> CursorMCPDiff {
        let existing = try loadExistingObject()
        return try makeDiff(existing: existing, merged: mergeAskKey(into: existing ?? [:]))
    }
}
