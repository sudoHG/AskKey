import SwiftUI
import XCTest
@testable import AskKeyiOSKit

/// Renders every screen state from the app's own SwiftUI views with fixed
/// states, in English and Simplified Chinese, for review. `build-ios.sh
/// test` passes the output directory; CI uploads it.
@MainActor
final class ScreenRenderTests: XCTestCase {
    private static let languages = ["en", "zh-Hans"]
    private static let mac = "Studio Mac"
    private static let pairedAt = Date(timeIntervalSince1970: 1_793_000_000)
    /// An iPhone screen in points; taller content makes a taller image.
    private static let screenSize = CGSize(width: 393, height: 852)

    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SCREEN_RENDER_DIRECTORY"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyiOSScreens", isDirectory: true)
    }

    private func render<Screen: View>(_ name: String, _ screen: Screen,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var images: [Data] = []
        for language in Self.languages {
            let content = screen
                .frame(width: Self.screenSize.width)
                .frame(minHeight: Self.screenSize.height, alignment: .top)
                .background(Color(uiColor: .systemGroupedBackground))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "\(name) did not render", file: file, line: line)
            XCTAssertGreaterThanOrEqual(image.size.height, Self.screenSize.height, file: file, line: line)
            let data = try XCTUnwrap(image.pngData(), file: file, line: line)
            try data.write(to: outputDirectory.appendingPathComponent("\(name)-\(language).png"))
            images.append(data)
        }
        XCTAssertNotEqual(images[0], images[1], "\(name) looks the same in both languages", file: file, line: line)
    }

    func testWelcome() throws {
        try render("01-welcome", WelcomeContent(step: .intro, onContinue: {}))
        try render("02-welcome-network-failure", WelcomeContent(step: .failed(.networkUnavailable), onContinue: {}))
    }

    func testScanner() throws {
        try render("03-scanner-camera-unavailable",
                   ScannerContent(camera: .unavailable, problem: nil, isSending: false, onDismissProblem: {},
                                  onCancel: {}) { EmptyView() })
        try render("04-scanner-expired-code",
                   ScannerContent(camera: .unavailable, problem: .expired, isSending: false, onDismissProblem: {},
                                  onCancel: {}) { EmptyView() })
    }

    func testPairingCode() throws {
        let display = PairingCodeDisplay(digits: "123 456", macName: Self.mac, confirmed: false)
        try render("05-pairing-no-code-yet",
                   PairingCodeContent(display: nil, isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
        try render("06-pairing-code",
                   PairingCodeContent(display: display, isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
        try render("07-pairing-face-id-cancelled",
                   PairingCodeContent(display: display, isConfirming: false, problem: .cancelled, onConfirm: {},
                                      onCancel: {}))
        try render("08-pairing-confirmed",
                   PairingCodeContent(display: PairingCodeDisplay(digits: "123 456", macName: Self.mac, confirmed: true),
                                      isConfirming: false, problem: nil, onConfirm: {}, onCancel: {}))
    }

    func testPairingOutcome() throws {
        try render("09-pairing-failed-no-challenge",
                   PairingResultContent(outcome: .failed(.noChallenge), onDone: {}))
        try render("10-pairing-paired", PairingResultContent(outcome: .paired(macName: Self.mac), onDone: {}))
    }

    func testPairedMacs() throws {
        let row = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt, lastReachedAt: nil)
        try render("11-paired-macs-one-mac",
                   PairedMacsContent(rows: [row], accountNotice: nil, listNotice: nil, records: [], onPair: {},
                                     onRemove: { _ in }, onDismissNotice: {}))
        let reached = PairedMacRow(id: "mac", name: Self.mac, pairedAt: Self.pairedAt,
                                   lastReachedAt: Self.pairedAt.addingTimeInterval(600))
        let records = [
            DeliveryRecord(recordName: "a", arrivedAt: Self.pairedAt.addingTimeInterval(300), source: .polling),
            DeliveryRecord(recordName: "b", arrivedAt: Self.pairedAt.addingTimeInterval(600), source: .push),
        ]
        try render("12-paired-macs-reached",
                   PairedMacsContent(rows: [reached], accountNotice: nil,
                                     listNotice: .removed(name: "Office Mac", macWasTold: true), records: records,
                                     onPair: {}, onRemove: { _ in }, onDismissNotice: {}))
        try render("13-paired-macs-empty-signed-out",
                   PairedMacsContent(rows: [], accountNotice: .signedOut, listNotice: .removedByMac(name: Self.mac),
                                     records: [], onPair: {}, onRemove: { _ in }, onDismissNotice: {}))
    }

    func testUnusableIdentity() throws {
        try render("14-unusable-identity", UnusableIdentityContent(isResetting: false, resetFailed: false, onReset: {}))
    }
}
