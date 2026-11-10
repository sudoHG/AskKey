import AppKit
import AskKeyTestSupport
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices

/// Renders the Devices section and every pairing sheet step offscreen in
/// both languages, so a layout that fails to draw or a missing translation
/// fails here before CI captures the windows.
@MainActor
final class DevicesSettingsRenderTests: AskKeyAppTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyDeviceRenders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryPairingStepAndTheListRenderInBothLanguages() async throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let harness = try DeviceCoordinatorHarness()
            defer { try? harness.close() }
            await harness.coordinator.launch()
            let model = DevicesSettingsModel(coordinator: harness.coordinator)

            await model.pairDevice()
            guard case .qrCode(let text, _) = try XCTUnwrap(model.sheet).stage else { return XCTFail("the QR code") }
            try render(DevicePairingSheet(model: model), as: "\(language)-qr-code")
            try await harness.phone.scan(text)
            await harness.coordinator.refresh()
            try render(DevicePairingSheet(model: model), as: "\(language)-waiting")
            try await harness.phone.poll()
            await harness.coordinator.refresh()
            let entry = try render(DevicePairingSheet(model: model), as: "\(language)-code-entry")
            let fields = Self.textFields(in: entry)
            XCTAssertEqual(fields.count, 1)
            XCTAssertNil(fields.first?.contentType, "the code field is not a one-time-code or autofill field")
            XCTAssertNotEqual(fields.first?.contentType, .oneTimeCode)

            model.codeEntry = "000 000"
            await model.confirm()
            try render(DevicePairingSheet(model: model), as: "\(language)-wrong-code")
            let shown = await harness.phone.shownCode()
            harness.script.authenticationResults = [.cancelled]
            model.codeEntry = try XCTUnwrap(shown)
            await model.confirm()
            try render(DevicePairingSheet(model: model), as: "\(language)-authentication-cancelled")
            await model.confirm()
            try await harness.phone.confirm()
            try await harness.phone.poll()
            await harness.coordinator.refresh()
            try render(DevicePairingSheet(model: model), as: "\(language)-paired")
            await model.closeSheet()
            try await harness.phone.poll()
            await harness.coordinator.refresh()

            try render(DevicesSettingsSection(model: model).frame(width: 712), as: "\(language)-list")
            model.requestRemoval(try XCTUnwrap(harness.coordinator.devices.first))
            try render(DevicesSettingsSection(model: model).frame(width: 712), as: "\(language)-remove")
            model.cancelRemoval()
            harness.backend.accountState = .noAccount
            await harness.coordinator.devicesOpened()
            try render(DevicesSettingsSection(model: model).frame(width: 712), as: "\(language)-icloud-signed-out")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 18)
    }

    @discardableResult
    private func render<V: View>(_ view: V, as name: String) throws -> NSView {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        XCTAssertGreaterThan(hosting.bounds.width, 100, name)
        XCTAssertGreaterThan(hosting.bounds.height, 60, name)
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        XCTAssertGreaterThan(data.count, 5_000, "\(name) did not render")
        return hosting
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        let own = (view as? NSTextField).map { [$0] }?.filter(\.isEditable) ?? []
        return own + view.subviews.flatMap(textFields(in:))
    }
}
