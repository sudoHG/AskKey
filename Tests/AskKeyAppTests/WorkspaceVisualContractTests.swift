import XCTest
import CryptoKit
import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class WorkspaceVisualContractTests: WorkspaceVisualContractTestSupport {
    @MainActor
    func testManagementWindowAppliesTheFrozenFrameAndKeepsFunctionalSystemTrafficLights() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "请旨"

        ManagementWindowConfiguration.apply(to: window)

        XCTAssertEqual(window.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, 620, accuracy: 2)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 980, height: 620))
        XCTAssertEqual(window.contentMaxSize, NSSize(width: 980, height: 620))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(window.title, "请旨")
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)

        let beforeZoom = window.frame
        window.zoom(nil)
        XCTAssertEqual(window.frame.size.width, beforeZoom.size.width, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, beforeZoom.size.height, accuracy: 2)
    }

    @MainActor
    func testManagementWindowStaysFrozenAfterSwiftUIContentSizeLayout() {
        _ = NSApplication.shared
        let viewModel = makePreviewViewModel()
        viewModel.hasCompletedOnboarding = true
        let window = ManagementWindowConfiguration.makeWindow(
            rootView: SettingsView()
                .environment(viewModel)
                .frame(
                    width: WorkspaceVisualContract.windowWidth,
                    height: WorkspaceVisualContract.windowHeight
                )
        )
        window.title = "请旨"

        let observers = ManagementWindowConfiguration.installObservers()
        defer {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        var restoredOversizedFrame = false
        let watchResizes: (NSWindow) -> NSObjectProtocol = { target in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: target,
                queue: nil
            ) { note in
                guard let resized = note.object as? NSWindow else { return }
                if resized.frame.height > WorkspaceVisualContract.windowHeight + 2 {
                    restoredOversizedFrame = true
                }
            }
        }
        let resizeWatcher = watchResizes(window)
        defer { NotificationCenter.default.removeObserver(resizeWatcher) }

        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        restoredOversizedFrame = false
        pumpWindowLayout(window)
        window.setContentSize(ManagementWindowConfiguration.frameSize)
        window.contentView?.invalidateIntrinsicContentSize()
        window.contentView?.needsLayout = true
        pumpWindowLayout(window)

        XCTAssertFalse(
            restoredOversizedFrame,
            "SwiftUI content-size layout restored a 652pt outer frame"
        )
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertEqual(window.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, 620, accuracy: 2)
        XCTAssertEqual(window.contentView?.frame.origin.x ?? -1, 0, accuracy: 2)
        XCTAssertEqual(window.title, "请旨")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        let beforeZoom = window.frame
        window.zoom(nil)
        XCTAssertEqual(window.frame.size.width, beforeZoom.size.width, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, beforeZoom.size.height, accuracy: 2)

        let oversized = makeSwiftUILikeManagementWindow(viewModel: viewModel)
        XCTAssertGreaterThan(oversized.frame.height, WorkspaceVisualContract.windowHeight + 2)
        let oversizedWatcher = watchResizes(oversized)
        defer {
            NotificationCenter.default.removeObserver(oversizedWatcher)
            oversized.close()
        }
        restoredOversizedFrame = false
        ManagementWindowConfiguration.apply(to: oversized)
        oversized.makeKeyAndOrderFront(nil)
        pumpWindowLayout(oversized)
        oversized.setContentSize(ManagementWindowConfiguration.frameSize)
        oversized.contentView?.invalidateIntrinsicContentSize()
        pumpWindowLayout(oversized)
        XCTAssertFalse(restoredOversizedFrame)
        XCTAssertTrue(oversized.canBecomeKey)
        XCTAssertEqual(oversized.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(oversized.frame.size.height, 620, accuracy: 2)
        window.close()
    }
}
