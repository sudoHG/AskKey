import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyHelper

final class HelperLocalizationTests: XCTestCase {
    func testHelperCopyUsesTheProcessLanguageAndPreservesChineseWording() {
        let reminder = "Ask Key: Query the credential catalog before connecting."
        for language in ["zh-Hans", "zh-CN", "zh_TW", "zh"] {
            XCTAssertEqual(HelperLocalization.localized(reminder, preferredLanguages: [language]),
                           "Ask Key：连接前先查询凭证目录。")
            XCTAssertEqual(HelperLocalization.localized("Ask Key (AskKey)", preferredLanguages: [language]),
                           "Ask Key (AskKey / 请旨)")
        }
        for languages in [["en-US"], ["fr-FR", "zh-Hans"], []] {
            XCTAssertEqual(HelperLocalization.localized(reminder, preferredLanguages: languages), reminder)
            XCTAssertEqual(HelperLocalization.localized("Ask Key (AskKey)", preferredLanguages: languages),
                           "Ask Key (AskKey)")
        }
        XCTAssertEqual(HelperLocalization.localized("Unknown key", preferredLanguages: ["zh-Hans"]), "Unknown key")
    }

    func testMissingOrInvalidCatalogFallsBackToEnglish() throws {
        let key = "Ask Key: Query the credential catalog before connecting."
        XCTAssertEqual(HelperLocalization.localized(key, preferredLanguages: ["zh-Hans"], catalogURL: nil), key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Localizable.xcstrings")
        XCTAssertEqual(HelperLocalization.localized(key, preferredLanguages: ["zh-Hans"], catalogURL: catalog), key)
        try Data("invalid JSON".utf8).write(to: catalog)
        XCTAssertEqual(HelperLocalization.localized(key, preferredLanguages: ["zh-Hans"], catalogURL: catalog), key)
    }

    func testCopiedHelperLoadsAdjacentResourcesAndWorksWithoutThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("askkey")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        try FileManager.default.copyItem(at: products.appendingPathComponent("askkey"), to: helper)
        XCTAssertTrue(try initialize(helper, root: root).hasPrefix("Ask Key (AskKey) manages"))

        let bundle = root.appendingPathComponent("AskKey_AskKeyHelper.bundle")
        try FileManager.default.copyItem(at: products.appendingPathComponent(bundle.lastPathComponent), to: bundle)
        let catalog = try XCTUnwrap(Bundle(url: bundle)?.url(forResource: "Localizable", withExtension: "xcstrings"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        var strings = try XCTUnwrap(json["strings"] as? [String: Any])
        strings["Ask Key (AskKey)"] = ["localizations": [
            "en": ["stringUnit": ["value": "Localized helper resource"]],
            "zh-Hans": ["stringUnit": ["value": "Localized helper resource"]],
        ]]
        json["strings"] = strings
        try JSONSerialization.data(withJSONObject: json).write(to: catalog)
        XCTAssertTrue(try initialize(helper, root: root).hasPrefix("Localized helper resource manages"))
    }

    private func initialize(_ helper: URL, root: URL) throws -> String {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["mcp"]
        process.environment = ProcessInfo.processInfo.environment
            .filter { !$0.key.hasPrefix("ASKKEY_") }
            .merging(["ASKKEY_DEBUG_RUN_DIRECTORY": try physicalTestDirectory(root).path]) { _, fixture in fixture }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n".utf8))
        try input.fileHandleForWriting.close()
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !process.isRunning }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 5), .completed)
        guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
        XCTAssertEqual(process.terminationStatus, 0)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["instructions"] as? String)
    }
}
