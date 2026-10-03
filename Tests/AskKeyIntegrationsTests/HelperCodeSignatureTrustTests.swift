import Foundation
import XCTest
@testable import AskKeyIntegrations

final class HelperCodeSignatureTrustTests: XCTestCase {
    func testAdHocBundleAcceptsOnlyItsSealedHelper() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Ask Key.app")
        let host = app.appendingPathComponent("Contents/MacOS/AskKeyApp")
        let helper = app.appendingPathComponent("Contents/Helpers/askkey")
        for executable in [host, helper] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
            try run(["--force", "--sign", "-", executable.path])
        }
        let plist: [String: String] = [
            "CFBundleExecutable": "AskKeyApp", "CFBundleIdentifier": "com.sudohg.askkey.test",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run(["--force", "--sign", "-", app.path])
        XCTAssertTrue(HelperCodeSignatureTrust.matchesHost(helper: helper, host: host))
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(
            helper: alias.appendingPathComponent("Contents/Helpers/askkey"), host: host
        ))

        // A valid signature is insufficient outside this exact app's helper location.
        let foreignApp = root.appendingPathComponent("Other.app")
        try FileManager.default.copyItem(at: app, to: foreignApp)
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(
            helper: foreignApp.appendingPathComponent("Contents/Helpers/askkey"), host: host
        ))
        let foreign = root.appendingPathComponent("askkey")
        try FileManager.default.copyItem(at: helper, to: foreign)
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(helper: foreign, host: host))

        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: foreign)
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(helper: helper, host: host))
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.copyItem(at: foreign, to: helper)
        XCTAssertTrue(HelperCodeSignatureTrust.matchesHost(helper: helper, host: host))

        // Independently re-signing a replacement must not bypass the host's resource seal.
        try run(["--force", "--sign", "-", "--identifier", "foreign.helper", helper.path])
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(helper: helper, host: host))
        try run(["--remove-signature", helper.path])
        XCTAssertFalse(HelperCodeSignatureTrust.matchesHost(helper: helper, host: host))
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "HelperCodeSignatureTrustTests.codesign", code: Int(process.terminationStatus))
        }
    }
}
