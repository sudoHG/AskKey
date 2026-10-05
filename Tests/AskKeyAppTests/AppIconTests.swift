import AppKit
import XCTest
@testable import AskKeyAppKit

final class AppIconTests: AskKeyAppTestCase {
    func testBundleIconTakesPrecedenceOverApplicationIcon() throws {
        try withBundle { bundle, resources in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            // A single PNG-backed 32px representation in an ICNS container.
            var icon = Data("icns".utf8)
            appendLength(png.count + 16, to: &icon)
            icon.append(Data("icp5".utf8))
            appendLength(png.count + 8, to: &icon)
            icon.append(png)
            try icon.write(to: resources.appendingPathComponent("AppIcon.icns"))

            var fallbackUsed = false
            func fallback() -> NSImage {
                fallbackUsed = true
                return NSImage(size: NSSize(width: 1, height: 1))
            }
            let image = AppIcon.load(bundle: bundle, fallback: fallback)

            XCTAssertFalse(fallbackUsed)
            XCTAssertEqual(image.size, NSSize(width: 32, height: 32))
            XCTAssertFalse(image.representations.isEmpty)
        }
    }

    func testMissingResourceReturnsApplicationIcon() throws {
        try withBundle { bundle, _ in
            let fallback = NSImage(size: NSSize(width: 16, height: 16))
            XCTAssertTrue(AppIcon.load(bundle: bundle, fallback: { fallback }) === fallback)
        }
    }

    func testInvalidResourceReturnsApplicationIcon() throws {
        try withBundle { bundle, resources in
            try Data("invalid icon".utf8).write(to: resources.appendingPathComponent("AppIcon.icns"))
            let fallback = NSImage(size: NSSize(width: 16, height: 16))
            XCTAssertTrue(AppIcon.load(bundle: bundle, fallback: { fallback }) === fallback)
        }
    }

    func testMissingApplicationIconReturnsEmptyImage() throws {
        try withBundle { bundle, _ in
            XCTAssertTrue(AppIcon.load(bundle: bundle, fallback: { nil }).representations.isEmpty)
        }
    }

    private func appendLength(_ length: Int, to data: inout Data) {
        var value = UInt32(length).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func withBundle(_ body: (Bundle, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.sudohg.askkey.tests.icon",
            "CFBundlePackageType": "APPL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try body(XCTUnwrap(Bundle(url: directory)), resources)
    }
}
