import XCTest
@testable import AskKeyVault

final class EnvFileFormatRepairTests: XCTestCase {
    func testParseRemovesTrailingCommentAfterDoubleQuotedValue() {
        XCTAssertEqual(
            EnvFileFormat.parse("TOKEN=\"abc\" # a comment").map(\.value),
            ["abc"]
        )
    }

    func testParseIgnoresAssignmentWhitespaceBeforeQuotedValue() {
        XCTAssertEqual(
            EnvFileFormat.parse("TOKEN= \"abc\"").map(\.value),
            ["abc"]
        )
    }

    func testParseRoundTripsLineEscapes() {
        let value = #"a\b"c"#
        XCTAssertEqual(
            EnvFileFormat.parse(EnvFileFormat.line(name: "TOKEN", value: value)).map(\.value),
            [value]
        )
    }

    func testParseValidatedSupportsCommentsExportsQuotesAndEscapes() throws {
        let pairs = try EnvFileFormat.parseValidated(
            "export TOKEN=\"abc\" # comment\nSINGLE='a # b' # comment\nBARE=raw#hash\n"
        )
        XCTAssertEqual(pairs.map(\.name), ["TOKEN", "SINGLE", "BARE"])
        XCTAssertEqual(pairs.map(\.value), ["abc", "a # b", "raw#hash"])
    }

    func testParseValidatedRejectsDuplicateAndInvalidLinesWithoutValueText() {
        XCTAssertThrowsError(try EnvFileFormat.parseValidated("TOKEN=one\nTOKEN=two\n")) { error in
            guard case EnvFileFormatError.duplicateKey(line: 2) = error else {
                return XCTFail("expected duplicateKey, got \(error)")
            }
            XCTAssertEqual((error as? EnvFileFormatError)?.localizationKey, "env.import.duplicateKey")
            XCTAssertFalse(error.localizedDescription.contains("one"))
            XCTAssertFalse(error.localizedDescription.contains("two"))
        }

        XCTAssertThrowsError(try EnvFileFormat.parseValidated("not-an-assignment\n")) { error in
            guard case EnvFileFormatError.invalidLine(line: 1) = error else {
                return XCTFail("expected invalidLine, got \(error)")
            }
        }

        XCTAssertThrowsError(try EnvFileFormat.parseValidated("BAD-NAME=value\n")) { error in
            guard case EnvFileFormatError.invalidKey(line: 1) = error else {
                return XCTFail("expected invalidKey, got \(error)")
            }
        }
    }

    func testParseValidatedRejectsMultilineQuotedValueAtTheFirstLine() {
        XCTAssertThrowsError(try EnvFileFormat.parseValidated("TOKEN=\"one\nNEXT=two\n")) { error in
            guard case EnvFileFormatError.multilineValue(line: 1) = error else {
                return XCTFail("expected multilineValue, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("one"))
            XCTAssertFalse(error.localizedDescription.contains("two"))
        }
    }
}
