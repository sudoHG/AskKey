import AppKit
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ApprovalVariableLineTests: AskKeyAppTestCase {
    func testCopyAndAccessibilityKeepOriginalTextIncludingUnicodeAndPartialSelections() {
        let variable = "STAGING_SERVICE_ACCESS_TOKEN"
        let line = ApprovalLine(format: "%1$@ → environment variable %2$@", plain: ["API Token 🙂"], code: [variable])
        let view = ApprovalVariableLine.TextView()
        view.configure(line)
        XCTAssertTrue(view.string.contains("_\u{200b}"))
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertEqual(view.selectedPlainText, line.plainText)
        XCTAssertEqual(view.accessibilityValue() as? String, line.plainText)
        XCTAssertEqual(view.accessibilitySelectedText(), line.plainText)
        let originalRange = NSRange(location: 0, length: (line.plainText as NSString).length)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), originalRange.length)
        XCTAssertEqual(view.accessibilityString(for: originalRange), line.plainText)
        XCTAssertEqual(view.accessibilityAttributedString(for: originalRange)?.string, line.plainText)
        let protectedAccess = Array("ACCESS").map(String.init).joined(separator: "\u{2060}")
        view.setSelectedRange((view.string as NSString).range(of: protectedAccess))
        XCTAssertEqual(view.selectedPlainText, "ACCESS")
        view.setSelectedRange((view.string as NSString).range(of: "🙂"))
        XCTAssertEqual(view.selectedPlainText, "🙂")
        let underscore = (view.string as NSString).range(of: "_")
        view.setSelectedRange(NSRange(location: underscore.location, length: 3))
        XCTAssertEqual(view.selectedPlainText, "_S", "Inserted break opportunities never enter selected/copied text")
    }

    func testActualTextLayoutBreaksVariableOnlyAfterUnderscores() throws {
        let variable = "STAGING_SERVICE_01_ACCESS_TOKEN"
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(format: "%@", code: [variable]))
        let size = view.measuredSize(width: 100)
        XCTAssertGreaterThan(size.height, 20)
        let manager = try XCTUnwrap(view.layoutManager)
        var fragments: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let fragment = (view.string as NSString).substring(with: characters)
                .replacingOccurrences(of: "\u{200b}", with: "").replacingOccurrences(of: "\u{2060}", with: "")
            fragments.append(fragment)
        }
        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(fragments.joined(), variable)
        XCTAssertTrue(fragments.dropLast().allSatisfy { $0.hasSuffix("_") }, "Never split an underscore-delimited word: \(fragments)")
    }
}
