import AppKit
import SwiftUI
import XCTest
import AskKeyCore
@testable import AskKeyAppKit

final class ReviewPrivateNotesTests: AskKeyAppTestCase {
    @MainActor
    func testRedactedPrivateNotesCannotAcceptEditsUntilRevealed() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "ReviewPrivateNotes-\(UUID())")!
        let model = VaultViewModel(runtimeFileCleanupFailures: { false }, accessRecords: .empty, eraseLocalLibrary: { _, _, _ in }, unlockVault: {},
            beginManagementSession: { _ in }, authenticateDeviceOwner: { _ in nil },
            preferences: AppPreferences(defaults: defaults), loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) })
        let credential = ManagedTextCredential(id: "synthetic", name: "Synthetic", value: nil,
            usageInstructions: "", privateNotes: nil, groupName: nil, environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .text, originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil, components: [])
        for existing in [credential, nil] {
            let host = NSHostingView(rootView: CredentialEditorView(credential: existing, initialMoreExpanded: true).environment(model))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 1000), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let field = try XCTUnwrap(findPrivateNotes(in: host))
            XCTAssertEqual(field.isEnabled, existing == nil)
        }
    }

    @MainActor
    private func findPrivateNotes(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           ["Only you can see this", "只有你能看到"].contains(field.placeholderString ?? "") { return field }
        for child in view.subviews {
            if let match = findPrivateNotes(in: child) { return match }
        }
        return nil
    }
}
