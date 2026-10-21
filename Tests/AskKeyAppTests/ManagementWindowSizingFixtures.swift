import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit

/// Uses the same factory and root sizing wrapper as ensureManagementWindow.
/// Windows stay hidden except in the explicitly gated CI lifecycle test.
@MainActor
final class ManagementWindowSizingHost {
    let window: NSWindow
    let view: NSView
    let measurement = ManagementRootMeasurement()

    init(model: NoticeLayoutFixtures.Model, detail: Bool = false) {
        _ = NSApplication.shared
        let content: AnyView
        if detail {
            model.vault.reloadCredentials()
            content = AnyView(CredentialManagementView(
                initialRoute: .credentialDetail("synthetic-notice-layout"),
                selectedCredentialID: "synthetic-notice-layout", previewMode: true
            ).tint(Theme.accent))
        } else {
            content = AnyView(SettingsView())
        }
        let measurement = measurement
        window = ManagementWindowConfiguration.makeWindow(rootView: content
            .environment(model.vault)
            .environment(\.locale, model.vault.appLocale)
            .preferredColorScheme(.light)
            .background(GeometryReader { geometry in
                measurement.record(geometry.frame(in: .global))
            }))
        view = window.contentView!
        window.appearance = NSAppearance(named: .aqua)
        layout()
        XCTAssertFalse(window.isVisible)
    }

    func layout() {
        for _ in 0..<8 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    func close() { window.close() }

    func render(includingChrome: Bool = false) throws -> NSBitmapImageRep {
        try NoticeLayoutFixtures.render(includingChrome ? XCTUnwrap(view.superview) : view)
    }

    func scrollView() throws -> NSScrollView {
        var pending = [view]
        var scrollViews: [NSScrollView] = []
        while let child = pending.popLast() {
            if let scrollView = child as? NSScrollView,
               scrollView.convert(scrollView.bounds, to: nil).midX > WorkspaceVisualContract.sidebarWidth {
                scrollViews.append(scrollView)
            }
            pending.append(contentsOf: child.subviews)
        }
        XCTAssertEqual(scrollViews.count, 1)
        return try XCTUnwrap(scrollViews.first)
    }

    func export(_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MANAGEMENT_WINDOW_RENDER_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render(includingChrome: true).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        XCTAssertFalse(window.isVisible)
    }
}

@MainActor
final class ManagementRootMeasurement {
    var frame: CGRect = .zero

    func record(_ frame: CGRect) -> Color {
        self.frame = frame
        return .clear
    }
}
