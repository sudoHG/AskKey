import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ManagementWindowSizingTests: AskKeyAppTestCase {
    func testHiddenWindowFillsItsDesignedFrameAcrossStatesAndRepeatedApplication() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let observers = ManagementWindowConfiguration.installObservers()
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        for language in ["en", "zh-Hans"] {
            for state in [SettingsEntryState.locked, .management, .onboarding, .empty] {
                let model = try NoticeLayoutFixtures.Model(language: language, state: state, recovery: false, broker: false)
                defer { model.close() }
                let host = ManagementWindowSizingHost(model: model)
                defer { host.close() }
                let controls = try controlFrames(host.window)
                for application in 0...2 {
                    if application == 1 { ManagementWindowConfiguration.apply(to: host.window) }
                    if application == 2 {
                        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: host.window)
                    }
                    host.layout()
                    try assertFrameAndEdges(host, model: model, context: "\(language) \(state) apply=\(application)")
                    XCTAssertEqual(try controlFrames(host.window), controls)
                    XCTAssertFalse(host.window.isVisible)
                }
            }
        }
    }

    func testLongCredentialDetailUsesTheSameFrameAndScrollableBottomEdge() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            let locked = try NoticeLayoutFixtures.Model(language: language, state: .locked, recovery: false, broker: false)
            defer { locked.close() }
            let lockedHost = ManagementWindowSizingHost(model: locked)
            defer { lockedHost.close() }
            ManagementWindowConfiguration.apply(to: lockedHost.window)
            lockedHost.layout()
            try assertFrameAndEdges(lockedHost, model: locked, context: "\(language) locked render")
            try lockedHost.export("\(language)-locked")

            let detail = try NoticeLayoutFixtures.Model(
                language: language, state: .management, recovery: false, broker: false, longContent: true
            )
            defer { detail.close() }
            let host = ManagementWindowSizingHost(model: detail, detail: true)
            defer { host.close() }
            for _ in 0..<2 {
                ManagementWindowConfiguration.apply(to: host.window)
                host.layout()
                try assertFrameAndEdges(host, model: detail, scrollable: true, context: "\(language) long detail")
            }
            let scrollView = try host.scrollView()
            let document = try XCTUnwrap(scrollView.documentView)
            XCTAssertGreaterThan(document.bounds.height, scrollView.contentView.bounds.height,
                                 "The detail must actually contain overflowing content")
            try host.export("\(language)-long-detail")
        }
    }

    func testVisibleWindowLifecycleKeepsTheDesignedFrameOnCI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true" else {
            throw XCTSkip("Visible window lifecycle runs only in the GitHub Actions test process")
        }
        try SDKMarkerTestSupport.checkTestProcess()
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let observers = ManagementWindowConfiguration.installObservers()
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        for state in [SettingsEntryState.locked, .management, .onboarding] {
            let model = try NoticeLayoutFixtures.Model(language: "en", state: state, recovery: false, broker: false)
            defer { model.close() }
            let host = ManagementWindowSizingHost(model: model)
            defer { host.close() }
            let designedFrame = host.window.frame
            for _ in 0..<2 {
                host.window.makeKeyAndOrderFront(nil)
                host.layout()
                XCTAssertTrue(host.window.isVisible)
                try assertFrameAndEdges(host, model: model, context: "CI visible \(state)")
                XCTAssertEqual(host.window.frame, designedFrame, "Activation must preserve the window position")
                ManagementWindowConfiguration.apply(to: host.window)
                host.layout()
                try assertFrameAndEdges(host, model: model, context: "CI reapplied \(state)")
                XCTAssertEqual(host.window.frame, designedFrame, "Reapplication must preserve the window position")
                host.window.orderOut(nil)
            }
        }
    }

    private func controlFrames(_ window: NSWindow) throws -> [CGRect] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            let button = try XCTUnwrap(window.standardWindowButton($0))
            XCTAssertFalse(button.isHidden)
            return button.convert(button.bounds, to: nil)
        }
    }

    private func assertFrameAndEdges(
        _ host: ManagementWindowSizingHost, model: NoticeLayoutFixtures.Model,
        scrollable: Bool = false, context: String
    ) throws {
        let raster = try NoticeRaster(host.render())
        let size = ManagementWindowConfiguration.frameSize
        XCTAssertEqual(host.window.frame.size, size, context)
        XCTAssertEqual(host.view.bounds, CGRect(origin: .zero, size: size), context)
        XCTAssertEqual(host.measurement.frame, CGRect(origin: .zero, size: size), context)
        XCTAssertFalse(host.window.styleMask.contains(.resizable), context)
        XCTAssertEqual(host.window.standardWindowButton(.zoomButton)?.isEnabled, false, context)
        let sidebar = try NoticeRaster(NoticeLayoutFixtures.notice(Theme.sidebarBackground.frame(height: 2), model: model, width: 2))
        XCTAssertTrue((0..<raster.height).allSatisfy {
            raster.matchesPixel(x: 0, y: $0, other: sidebar, otherX: 0, otherY: 0)
        }, "Sidebar must fill the entire height: \(context)")
        let state = model.vault.settingsEntryState
        if scrollable || state == .onboarding || state == .empty {
            // Hidden native scroll views may be transparent in CI bitmaps.
            // Their real viewport must still reach the window's bottom edge.
            let scrollView = try host.scrollView()
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            XCTAssertEqual(frame.minY, 0, accuracy: 0.5, context)
            XCTAssertEqual(frame.maxX, size.width, accuracy: 0.5, context)
            XCTAssertGreaterThan(frame.height, 0, context)
        } else {
            let content = try NoticeRaster(NoticeLayoutFixtures.notice(Theme.windowBackground.frame(height: 2), model: model, width: 2))
            let columnStart = Int((WorkspaceVisualContract.sidebarWidth + 2) * raster.scale)
            XCTAssertTrue((columnStart..<raster.width).allSatisfy {
                raster.matchesPixel(x: $0, y: raster.height - 1, other: content, otherX: 0, otherY: 0)
            }, "Content must fill the bottom edge: \(context)")
        }
    }
}
