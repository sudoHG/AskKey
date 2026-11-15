import AppKit
import SwiftUI
import XCTest
import AskKeyDevices
import AskKeyVault
@testable import AskKeyAppKit

/// Renders the access records that name the approving iPhone (#329) in the
/// real management window, in English and Simplified Chinese, as 2x PNGs:
/// a local Allow and Deny next to a remote Allow Once, two reads under a
/// remote timed allowance and a remote Deny, then the longest device name a
/// Mac keeps, cut in the middle. The window is built as
/// `AppDelegate.ensureManagementWindow` builds it and is never ordered in.
/// Set `REMOTE_APPROVAL_RENDER_DIRECTORY` to keep the PNGs; they go to its
/// `access-records` folder. Every name and value is synthetic.
@MainActor
final class AccessRecordRenderTests: AskKeyAppTestCase {
    private var directory: URL!
    private var keepsRenders = false
    private var previousIcon: NSImage?

    override func setUp() async throws {
        if let path = ProcessInfo.processInfo.environment["REMOTE_APPROVAL_RENDER_DIRECTORY"] {
            directory = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("access-records", isDirectory: true)
            keepsRenders = true
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKeyAccessRecordRenders-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        previousIcon = NSApp.applicationIconImage
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSApp.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("assets/AppIcon.icon/Assets/AppIcon.png"))
    }

    override func tearDown() async throws {
        NSApp.applicationIconImage = previousIcon
        if !keepsRenders { try? FileManager.default.removeItem(at: directory) }
    }

    func testAccessRecordsNameTheApprovingIPhoneInBothLanguages() throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        var names: [String] = []
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let tag = language == "en" ? "en" : "zh"
            let phone = "Synthetic iPhone"
            let approved = language == "en"
                ? "Approved on “Synthetic iPhone”" : "已在“Synthetic iPhone”上批准" // i18n-literal: Expected Simplified Chinese catalog value.
            let denied = language == "en"
                ? "Denied on “Synthetic iPhone”" : "已在“Synthetic iPhone”上拒绝" // i18n-literal: Expected Simplified Chinese catalog value.
            let decisions = try render(records(device: phone), language: language,
                                       as: "01-\(tag)-access-records-remote-decisions")
            XCTAssertEqual(decisions.map(\.detail), [denied, approved, approved, approved, nil, nil])
            names.append("01-\(tag)-access-records-remote-decisions")

            // The longest name the Mac keeps for a paired device, in wide characters.
            let long = DeviceDisplayName.clean(String(repeating: "合成测试设备名称", count: 10)) // i18n-literal: Synthetic device name.
            XCTAssertEqual(long.unicodeScalars.count, DeviceDisplayName.maximumScalarCount)
            let longRows = try render(records(device: long), language: language,
                                      as: "02-\(tag)-access-records-long-device-name")
            XCTAssertEqual(longRows.compactMap(\.detail).count, 4)
            names.append("02-\(tag)-access-records-long-device-name")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(Set(files), Set(names.map { $0 + ".png" }))
        XCTAssertEqual(names.count, 4)
    }

    // MARK: Records

    private func record(_ result: CredentialAccessEvent.Result, at minutes: Int, caller: String = "Codex",
                        executable: String = "deploy.sh", device: String?) -> CredentialAccessEvent {
        let today = Calendar.current.startOfDay(for: Date())
        return CredentialAccessEvent(
            timestamp: today.addingTimeInterval(TimeInterval((9 * 60 + minutes) * 60)),
            credentialID: "synthetic-notice-layout", operation: .runtimeRead, result: result,
            callerHint: caller, declaredPurpose: nil, executableBasename: executable, deviceName: device)
    }

    /// Newest first on screen: a remote Deny, two reads under a remote timed
    /// allowance, a remote Allow Once, then a local Deny and a local Allow.
    private func records(device: String) -> [CredentialAccessEvent] {
        [
            record(.allowed, at: 12, device: nil),
            record(.denied, at: 25, caller: "Claude Code", executable: "migrate.sh", device: nil),
            record(.allowed, at: 62, device: device),
            record(.allowed, at: 75, caller: "Cursor", executable: "backup.sh", device: device),
            record(.allowed, at: 81, caller: "Cursor", executable: "backup.sh", device: device),
            record(.denied, at: 90, caller: "Claude Code", executable: "rotate-keys.sh", device: device),
        ]
    }

    // MARK: Rendering

    /// The management window as `ensureManagementWindow` makes it, opened on
    /// Access records; returns the rows the window shows.
    private func render(_ records: [CredentialAccessEvent], language: String,
                        as name: String) throws -> [AccessRecordPresentation.Row] {
        let fixture = try NoticeLayoutFixtures.Model(language: language, state: .management, recovery: false,
                                                     broker: false, accessRecords: records)
        defer { fixture.close() }
        let navigation = ManagementNavigation()
        navigation.section = .accessRecords
        navigation.route = .accessRecords
        let window = ManagementWindowConfiguration.makeWindow(
            rootView: SettingsView(navigation: navigation)
                .environment(fixture.vault)
                .environment(\.locale, fixture.vault.appLocale)
        )
        defer { window.close() }
        ManagementWindowConfiguration.apply(to: window)
        window.appearance = NSAppearance(named: .aqua)
        settle(window)
        XCTAssertFalse(window.isVisible)
        // The default Library page never loads records; Access records loads
        // them on appear, so the window left the default page.
        XCTAssertEqual(navigation.route, .accessRecords, name)
        XCTAssertEqual(fixture.vault.credentialAccessRecords, records, name)
        try export(try XCTUnwrap(window.contentView?.superview), as: name, contentFrom: WorkspaceVisualContract.sidebarWidth)
        let presentation = AccessRecordPresentation(records: fixture.vault.credentialAccessRecords,
                                                    credentialName: { _ in "Synthetic API" })
        return presentation.sections.flatMap(\.rows)
    }

    private func settle(_ window: NSWindow) {
        let view = window.contentView!
        for _ in 0..<8 {
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Writes the PNG and fails when the part right of `contentFrom` points
    /// is a single color, as an offscreen window that drew nothing would be.
    private func export(_ view: NSView, as name: String, contentFrom: CGFloat) throws {
        let bitmap = try RemoteApprovalRenderTests.render(view)
        var colors = Set<String>()
        let scale = CGFloat(bitmap.pixelsWide) / max(view.bounds.width, 1)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
            for x in stride(from: Int(contentFrom * scale), to: bitmap.pixelsWide, by: 12) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                colors.insert(String(format: "%.2f %.2f %.2f", color.redComponent, color.greenComponent, color.blueComponent))
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "\(name) drew nothing")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "\(name) did not render")
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
