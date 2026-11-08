import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

/// Renders every backup sheet state offscreen in both languages, so a layout
/// that fails to draw or a missing translation fails here before CI captures.
@MainActor
final class BackupSheetRenderTests: BackupFlowTestCase {
    func testEveryBackupSheetStateRendersInBothLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupRenders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for language in ["en", "zh-Hans"] {
            let fixture = try makeFixture(language: language)
            XCTAssertEqual(AppLanguage.current, language)
            try fixture.text("Staging API", "synthetic-source-value", in: fixture.source)
            try fixture.text("Build Cache", "synthetic-cache-value", in: fixture.source)
            let (_, recoveryKey) = try fixture.sourceBackup()
            try fixture.text("Staging API", "synthetic-target-value", in: fixture.target)
            try fixture.openManagement(in: fixture.source)

            let export = BackupExportFlow(vault: fixture.viewModel, operations: fixture.operations)
            let exported = await export.start()
            XCTAssertTrue(exported)
            try render(BackupExportSheet(flow: export, onClose: {}), as: "\(language)-recovery-key", in: directory)

            try fixture.openManagement(in: fixture.target)
            let flow = BackupImportFlow(vault: fixture.viewModel, operations: fixture.operations)
            XCTAssertTrue(flow.chooseFile())
            flow.recoveryKey = "AAAA"
            XCTAssertFalse(flow.openBackup())
            try render(BackupImportSheet(flow: flow, onClose: {}), as: "\(language)-key-typo", in: directory)
            flow.recoveryKey = recoveryKey
            XCTAssertTrue(flow.openBackup())
            try render(BackupImportSheet(flow: flow, onClose: {}), as: "\(language)-preview", in: directory)
            let committed = await flow.confirm()
            XCTAssertTrue(committed)
            try render(BackupImportSheet(flow: flow, onClose: {}), as: "\(language)-result", in: directory)

            try render(
                FirstRunOnboardingView(onCreateCredential: {}, onImportCredential: {}, initialLaunchAtLoginEnabled: true)
                    .environment(fixture.viewModel)
                    .frame(width: 776, height: 620),
                as: "\(language)-welcome", in: directory
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 10)
    }

    private func render<V: View>(_ view: V, as name: String, in directory: URL) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        XCTAssertGreaterThan(hosting.bounds.width, 100, name)
        XCTAssertGreaterThan(hosting.bounds.height, 100, name)
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        XCTAssertGreaterThan(data.count, 5_000, "\(name) did not render")
    }
}
