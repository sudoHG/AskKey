import AppKit
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ApprovalVariableLineTests: AskKeyAppTestCase {
    func testDeliveredIdentifierMovesWholeToTheNextLine() throws {
        let variable = "STAGING_API_TOKEN"
        let line = ApprovalLine(format: "Staging API → environment variable %@", code: [variable])
        let view = ApprovalVariableLine.TextView()
        view.configure(line, codeWrapping: .identifier)
        _ = view.measuredSize(width: 160)
        let manager = try XCTUnwrap(view.layoutManager)
        var fragments: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            fragments.append((view.string as NSString).substring(with: characters)
                .replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{200b}", with: ""))
        }
        XCTAssertTrue(fragments.contains { $0.contains(variable) }, "\(fragments)")
        XCTAssertEqual(fragments.joined(), line.plainText)
    }

    func testCommandFlagsStayWholeAndAllExportsKeepTheExactCommand() throws {
        let command = "./deploy.sh " + (1...18).map { "--flag-\($0) value-\($0)" }.joined(separator: " ")
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(format: "%@", code: [command]), codeWrapping: .command)
        _ = view.measuredSize(width: 110)
        let manager = try XCTUnwrap(view.layoutManager)
        var fragments: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            fragments.append((view.string as NSString).substring(with: characters)
                .replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{200b}", with: ""))
        }
        XCTAssertEqual(fragments.joined(), command)
        XCTAssertFalse(fragments.contains { $0.trimmingCharacters(in: .whitespaces).hasSuffix("--") })
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), command)
        XCTAssertEqual(view.accessibilityValue(), command)
        view.setSelectedRange((view.string as NSString).range(of: ApprovalCopy.unbroken("--flag-12")))
        XCTAssertEqual(view.selectedPlainText, "--flag-12")
    }

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

    func testSixtyCharacterVariableFitsAndAllPasteboardExportsUseOriginalSelection() throws {
        let variable = String(repeating: "A", count: 60)
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(format: "%@", code: [variable]))
        let size = view.measuredSize(width: 100)
        XCTAssertGreaterThan(size.height, 40)
        let manager = try XCTUnwrap(view.layoutManager)
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, used, _, _, _ in
            XCTAssertLessThanOrEqual(used.maxX, 100, "A long word must not overflow the text container")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertTrue(pasteboard.types?.allSatisfy { $0 == .string || $0.rawValue == "NSStringPboardType" } == true)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: .string), variable)
        // Exercise the individual-type hook used by drag and Services, too.
        view.setSelectedRange(NSRange(location: 1, length: 30))
        pasteboard.clearContents()
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), view.selectedPlainText)
        XCTAssertFalse(view.writeSelection(to: pasteboard, type: .rtf))
    }
}
