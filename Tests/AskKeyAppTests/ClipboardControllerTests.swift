import AppKit
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ClipboardControllerTests: AskKeyAppTestCase {
    func testClipboardCleanupIsFixedAtSixtySeconds() {
        let defaults = UserDefaults(suiteName: "AskKeyTests.\(UUID().uuidString)")!
        defaults.set(15.0, forKey: "clipboardClearSeconds")
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.clipboardClearSeconds, 60)
    }

    func testPopoverAndAppTransitionsKeepSessionUntilMainWindowCloses() {
        var hasManagementSession = true
        let lifecycle = ManagementSessionLifecycle {
            hasManagementSession = false
        }

        lifecycle.handle(.popoverDisappeared)
        XCTAssertTrue(hasManagementSession)
        lifecycle.handle(.applicationDeactivated)
        XCTAssertTrue(hasManagementSession)
        lifecycle.handle(.windowClosed(identifier: "other"))
        XCTAssertTrue(hasManagementSession)
        lifecycle.handle(.windowClosed(identifier: "settings"))
        XCTAssertFalse(hasManagementSession)
    }

    func testCleanupDoesNotClearSameTextWrittenAgainByAnotherOwner() async throws {
        let pasteboard = NSPasteboard(name: .init("AskKeyTests.\(UUID().uuidString)"))
        let controller = ClipboardController(pasteboard: pasteboard)
        controller.copy("secret", clearAfter: 0.05)
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
    }
}
