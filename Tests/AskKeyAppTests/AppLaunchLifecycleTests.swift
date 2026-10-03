import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class AppLaunchLifecycleTests: AppLanguageExperienceTestSupport {
    func testActiveLaunchShowsDockMenuBarAndMainWindow() {
        let event = launchEvent(loginItem: false)
        var policy: NSApplication.ActivationPolicy?
        var activationCount = 0
        var hiddenWindowCount = 0
        let presentation = AppLaunchPresentation.plan(for: AppLaunchSource(event: event))
        presentation.apply(
            setActivationPolicy: { policy = $0 },
            activateApplication: { activationCount += 1 },
            hideMainWindow: { hiddenWindowCount += 1 }
        )

        XCTAssertEqual(AppLaunchSource(event: event), .active)
        XCTAssertEqual(policy, .regular)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(hiddenWindowCount, 0)
    }

    func testPackagedMenuBarIconLoadsFromMainAppResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKey.icon.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Ask Key.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.sudohg.askkey.icon-test</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(
            at: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Resources/MenuBarIcon.png"),
            to: resources.appendingPathComponent("MenuBarIcon.png")
        )

        let bundle = try XCTUnwrap(Bundle(url: app))
        let artwork = try XCTUnwrap(MenuBarIcon.artwork(in: bundle))
        XCTAssertGreaterThan(artwork.size.width, 0)
        XCTAssertGreaterThan(artwork.size.height, 0)
    }

    func testLoginItemLaunchKeepsOnlyTheMenuBarResident() {
        let event = launchEvent(loginItem: true)
        var policy: NSApplication.ActivationPolicy?
        var activationCount = 0
        var hiddenWindowCount = 0
        let presentation = AppLaunchPresentation.plan(for: AppLaunchSource(event: event))
        presentation.apply(
            setActivationPolicy: { policy = $0 },
            activateApplication: { activationCount += 1 },
            hideMainWindow: { hiddenWindowCount += 1 }
        )

        XCTAssertEqual(AppLaunchSource(event: event), .loginItem)
        XCTAssertEqual(policy, .accessory)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(hiddenWindowCount, 1)
    }
}
