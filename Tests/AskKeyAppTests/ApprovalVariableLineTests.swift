import AppKit
import SwiftUI
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

    func testMultiRangeCopyDragAndServicesExportEveryOriginalRangeInOrder() {
        let (view, original, first, second) = exportFixture()
        view.setAccessibilitySelectedTextRanges([NSValue(range: second), NSValue(range: first)])
        let expected = (original as NSString).substring(with: first) + "\n" + (original as NSString).substring(with: second)
        XCTAssertEqual(view.selectedRanges.count, 2)
        XCTAssertEqual(view.selectedPlainText, expected)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Copy uses this multi-type entry point; drag and Services also use
        // the individual-type entry point. Both must include every range.
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertNil(pasteboard.data(forType: .rtf))
        pasteboard.clearContents()
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertFalse(view.writeSelection(to: pasteboard, type: .rtf))
    }

    func testCmdEExportsOriginalMultiRangeTextThroughBothFindActions() {
        let (view, original, first, second) = exportFixture()
        view.setAccessibilitySelectedTextRanges([NSValue(range: first), NSValue(range: second)])
        let expected = (original as NSString).substring(with: first) + "\n" + (original as NSString).substring(with: second)
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.declareTypes([.string], owner: nil)
        defer { pasteboard.clearContents() }
        let item = NSMenuItem(title: "Use Selection for Find", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "e")
        item.tag = NSTextFinder.Action.setSearchString.rawValue
        pasteboard.setString("synthetic-old-search", forType: .string)
        view.performFindPanelAction(item)
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        pasteboard.setString("synthetic-old-search", forType: .string)
        view.performTextFinderAction(item)
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        // A single partial selection follows the same path.
        view.setAccessibilitySelectedTextRange(first)
        view.performFindPanelAction(item)
        XCTAssertEqual(pasteboard.string(forType: .string), (original as NSString).substring(with: first))
    }

    func testShareActionPassesOriginalMultiRangeSelectionAndUnselectedDocument() {
        let (view, original, first, second) = exportFixture()
        let capture = ShareCapture()
        view.delegate = capture
        view.setAccessibilitySelectedTextRanges([NSValue(range: first), NSValue(range: second)])
        view.orderFrontSharingServicePicker(nil)
        XCTAssertEqual(capture.items as? [String], [
            (original as NSString).substring(with: first) + "\n" + (original as NSString).substring(with: second)
        ])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.orderFrontSharingServicePicker(nil)
        XCTAssertEqual(capture.items as? [String], [original])
        XCTAssertEqual(capture.calls, 2)
        XCTAssertNil(view.window, "The delegate cancels presentation; this test never shows a picker or window")
    }

    func testAccessibilitySelectionsAndStringsUseOriginalUTF16Coordinates() throws {
        let (view, original, first, second) = exportFixture()
        view.setAccessibilitySelectedTextRange(second)
        XCTAssertEqual(view.accessibilitySelectedTextRange(), second)
        XCTAssertEqual(view.accessibilitySelectedText(), (original as NSString).substring(with: second))
        XCTAssertGreaterThan(view.selectedRange().length, second.length)
        view.setAccessibilitySelectedTextRanges([NSValue(range: first), NSValue(range: second)])
        XCTAssertEqual(view.accessibilitySelectedTextRanges()?.map(\.rangeValue), [first, second])
        XCTAssertEqual(view.accessibilitySelectedTextRange(), first)
        XCTAssertEqual(view.accessibilityString(for: second), (original as NSString).substring(with: second))
        XCTAssertEqual(view.accessibilityAttributedString(for: second)?.string, (original as NSString).substring(with: second))
        let rtf = try XCTUnwrap(view.accessibilityRTF(for: second))
        let decoded = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(decoded.string, (original as NSString).substring(with: second))
        let emoji = (original as NSString).range(of: "🙂")
        view.setSelectedRange((view.string as NSString).range(of: "🙂"))
        XCTAssertEqual(view.accessibilitySelectedTextRange(), emoji)
        XCTAssertEqual(view.accessibilityRange(for: emoji.location + 1), emoji)
        let invalid = NSRange(location: Int.max, length: Int.max)
        XCTAssertNil(view.accessibilityString(for: invalid))
        XCTAssertNil(view.accessibilityAttributedString(for: invalid))
        XCTAssertNil(view.accessibilityRTF(for: invalid))
        view.setAccessibilitySelectedTextRange(invalid)
        view.setAccessibilitySelectedTextRanges([NSValue(range: first), NSValue(range: invalid)])
        XCTAssertEqual(view.accessibilitySelectedTextRange(), emoji, "Invalid setters cannot partially change the selection")
        XCTAssertEqual(view.accessibilityRange(for: -1).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(for: (original as NSString).length).location, NSNotFound)
    }

    func testAccessibilityWrappedLinesStylesAndComposedCharactersUseOriginalRanges() throws {
        let view = ApprovalVariableLine.TextView()
        let code = "STAGING_SERVICE_ACCESS_TOKEN_" + String(repeating: "X", count: 30)
        let line = ApprovalLine(format: "%1$@\n%2$@", plain: ["🙂 e\u{301}"], code: [code])
        view.configure(line)
        let size = view.measuredSize(width: 100)
        view.frame = NSRect(origin: .zero, size: size)
        let manager = try XCTUnwrap(view.layoutManager)
        var expected: [NSRange] = []
        var offset = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let displayed = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let original = (view.string as NSString).substring(with: displayed)
                .replacingOccurrences(of: "\u{200b}", with: "").replacingOccurrences(of: "\u{2060}", with: "")
            expected.append(NSRange(location: offset, length: (original as NSString).length))
            offset += (original as NSString).length
        }
        XCTAssertGreaterThan(expected.count, 3)
        XCTAssertEqual(offset, (line.plainText as NSString).length)
        for (index, range) in expected.enumerated() {
            XCTAssertEqual(view.accessibilityRange(forLine: index), range)
            XCTAssertEqual(view.accessibilityLine(for: range.location), index)
            XCTAssertEqual(view.accessibilityLine(for: NSMaxRange(range) - 1), index)
            view.setAccessibilitySelectedTextRange(NSRange(location: range.location, length: 0))
            XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), index)
        }
        XCTAssertEqual(view.accessibilityRange(forLine: -1).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(forLine: expected.count).location, NSNotFound)
        XCTAssertEqual(view.accessibilityLine(for: Int.max), NSNotFound)
        let combined = (line.plainText as NSString).range(of: "e\u{301}")
        XCTAssertEqual(view.accessibilityRange(for: combined.location + 1), combined)
        let codeRange = (line.plainText as NSString).range(of: code)
        XCTAssertEqual(view.accessibilityStyleRange(for: codeRange.location + 10), codeRange)
        let visible = view.accessibilityVisibleCharacterRange()
        XCTAssertEqual(visible, NSRange(location: 0, length: (line.plainText as NSString).length))
        XCTAssertEqual(view.accessibilityString(for: visible), line.plainText)
        XCTAssertEqual(view.accessibilitySharedCharacterRange(), NSRange(location: 0, length: (line.plainText as NSString).length))
    }

    func testAccessibilityHandlesEmptyAndTrailingLinesInOriginalCoordinates() {
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(format: "%@\n", code: ["ACCESS_TOKEN"]))
        _ = view.measuredSize(width: 300)
        let length = (view.originalText as NSString).length
        XCTAssertEqual(view.accessibilityRange(forLine: 1), NSRange(location: length, length: 0))
        XCTAssertEqual(view.accessibilityLine(for: length), 1)
        view.setAccessibilitySelectedTextRange(NSRange(location: length, length: 0))
        XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 1)
        view.configure(ApprovalLine(format: "", code: []))
        _ = view.measuredSize(width: 300)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 0)
        XCTAssertEqual(view.accessibilityRange(forLine: 0), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.accessibilityLine(for: 0), 0)
    }

    func testAccessibilityGeometryMapsOriginalCharacterRangesToDisplayLayout() throws {
        let view = ApprovalVariableLine.TextView()
        let original = "STAGING_SERVICE_ACCESS_TOKEN"
        view.configure(ApprovalLine(format: "%@", code: [original]))
        view.frame = NSRect(origin: NSPoint(x: 20, y: 20), size: view.measuredSize(width: 300))
        let window = ManagementWindowConfiguration.makeWindow(rootView: Color.clear)
        defer { window.close() }
        try XCTUnwrap(window.contentView).addSubview(view)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        let displayed = (view.string as NSString).range(of: "K")
        let glyphs = manager.glyphRange(forCharacterRange: displayed, actualCharacterRange: nil)
        let local = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let screen = window.convertToScreen(view.convert(local, to: nil))
        let range = (original as NSString).range(of: "K")
        XCTAssertGreaterThan(displayed.location, range.location)
        XCTAssertEqual(view.accessibilityFrame(for: range), screen)
        XCTAssertEqual(view.accessibilityRange(for: NSPoint(x: screen.midX, y: screen.midY)), range)
        view.setAccessibilitySelectedTextRange(NSRange(location: range.location, length: 0))
        XCTAssertEqual(view.accessibilityFrame(for: NSRange(location: range.location, length: 0)),
                       view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil))
        XCTAssertEqual(view.accessibilityFrame(for: NSRange(location: Int.max, length: 1)), .zero)
        XCTAssertFalse(window.isVisible, "Geometry checks never order a window on screen")
    }

    private func exportFixture() -> (ApprovalVariableLine.TextView, String, NSRange, NSRange) {
        let first = "FIRST_\u{200b}TOKEN"
        let second = "SECOND_\u{2060}FILE"
        let line = ApprovalLine(format: "%1$@ → %2$@ / %3$@", plain: ["API 🙂"], code: [first, second])
        let view = ApprovalVariableLine.TextView()
        view.configure(line)
        return (view, line.plainText, (line.plainText as NSString).range(of: first), (line.plainText as NSString).range(of: second))
    }

    private final class ShareCapture: NSObject, NSTextViewDelegate {
        var items: [Any] = []
        var calls = 0

        func textView(_ textView: NSTextView, willShow servicePicker: NSSharingServicePicker, forItems items: [Any]) -> NSSharingServicePicker? {
            self.items = items
            calls += 1
            return nil
        }
    }
}
