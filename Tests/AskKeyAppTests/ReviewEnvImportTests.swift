import XCTest
import AskKeyCore
@testable import AskKeyApp

final class ReviewEnvImportTests: AskKeyAppTestCase {
    func testMalformedPastedEnvReportsLineNumberWithoutExposingValues() throws {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "zh-Hans"
        do {
            _ = try FrozenEnvImport.parse("FIRST=allowed\nTOKEN=private-value\nTOKEN=another-private-value")
            XCTFail("Expected duplicate-key rejection")
        } catch {
            XCTAssertEqual(FrozenEnvImport.errorMessage(error), "第 3 行：.env 文件中存在重复的变量名。")
            XCTAssertFalse(FrozenEnvImport.errorMessage(error).contains("private-value"))
        }
    }

    func testEnvFileImportRejectsSymlinksAndOversizedFilesBeforeParsing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewEnvImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.env")
        try Data("TOKEN=synthetic".utf8).write(to: regular)
        let symbolic = root.appendingPathComponent("symbolic.env")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: regular)
        XCTAssertThrowsError(try FrozenEnvImport.load(url: symbolic))
        let oversized = root.appendingPathComponent("oversized.env")
        try Data(repeating: 65, count: FileImport.maxByteCount + 1).write(to: oversized)
        XCTAssertThrowsError(try FrozenEnvImport.load(url: oversized))
        XCTAssertEqual(try FrozenEnvImport.load(url: regular).pairs.first?.value, "synthetic")
    }

    func testEnvFileImportPreservesQuotedValuesAndRejectsInvalidUTF8() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewEnvImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic.env")
        try Data("TOKEN=\"quoted # value\" # trailing comment".utf8).write(to: file)
        XCTAssertEqual(try FrozenEnvImport.load(url: file).pairs.first?.value, "quoted # value")
        try Data([0xff, 0xfe]).write(to: file)
        XCTAssertThrowsError(try FrozenEnvImport.load(url: file))
    }
}
