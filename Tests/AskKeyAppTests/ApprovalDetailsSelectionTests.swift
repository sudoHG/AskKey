import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ApprovalDetailsSelectionTests: AskKeyAppTestCase {
    func testDetailsPurposeKeepsTheUnverifiedQualifierTogetherAtTheCardWidth() throws {
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine("Deploy the staging site (not verified)"), textStyle: .details)
        _ = view.measuredSize(width: 177)
        let manager = try XCTUnwrap(view.layoutManager)
        var lines: [String] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            let range = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append((view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(lines, ["Deploy the staging site", "(not verified)"])
    }

    func testTextValueCopyExportsOriginalCharactersInBothLanguages() {
        ApprovalCardFixtures.withLanguages { _ in
            let original = "Deploy “Staging API” 🙂 e\u{301} (not verified)"
            let view = ApprovalVariableLine.TextView()
            view.configure(ApprovalLine(original), textStyle: .details)
            XCTAssertNotEqual(view.string, original)
            XCTAssertTrue(view.string.contains("\u{2060}"))
            XCTAssertTrue(view.string.contains("\u{00a0}"))
            assertExports(view, original: original)
        }
    }

    func testLineNoteAndPartialSelectionsExportOriginalSpacesAndUnicode() {
        let original = "Move “Staging API” to “Release Tools” 🙂"
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(original), textStyle: .detailsSecondary)
        assertExports(view, original: original)
        XCTAssertEqual((view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB),
                       NSColor(Theme.textSecondary).usingColorSpace(.sRGB))
        let name = (original as NSString).range(of: "Staging API")
        view.setAccessibilitySelectedTextRange(name)
        XCTAssertEqual(view.selectedPlainText, "Staging API")
        XCTAssertEqual(view.accessibilitySelectedTextRange(), name)
        XCTAssertGreaterThan(view.selectedRange().length, name.length)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "Staging API")
    }

    func testOriginalJoinersAndNoBreakSpacesArePreservedRatherThanStripped() {
        ApprovalCardFixtures.withLanguages { _ in
            let original = "“API \u{2060}Token\u{00a0}🙂” and “e\u{301} key”"
            let view = ApprovalVariableLine.TextView()
            view.configure(ApprovalLine(original), textStyle: .details)
            assertExports(view, original: original)
            for value in ["\u{2060}", "\u{00a0}", "🙂", "e\u{301}"] {
                let range = (original as NSString).range(of: value)
                view.setAccessibilitySelectedTextRange(range)
                XCTAssertEqual(view.selectedPlainText, value)
                XCTAssertEqual(view.accessibilityString(for: range), value)
            }
        }
    }

    func testTaggedMixedFontLineExportsEveryOriginalSegment() {
        let line = ApprovalLine(format: "%1$@ → %2$@", plain: ["“API Token”"], code: ["RELEASE_TOKEN"])
        let view = ApprovalVariableLine.TextView()
        view.configure(line, codeWrapping: .identifier, textStyle: .details, tag: .changed)
        assertExports(view, original: "\u{2009}" + ApprovalTag.changed.title + "\u{2009} " + line.plainText)
        view.setAccessibilitySelectedTextRange((view.originalText as NSString).range(of: "RELEASE_TOKEN"))
        XCTAssertEqual(view.selectedPlainText, "RELEASE_TOKEN")
    }

    func testShareUsesOriginalMultiRangeSelectionAndUnselectedText() {
        let original = "“First item” and “Second item”"
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine(original), textStyle: .details)
        let first = (original as NSString).range(of: "First item")
        let second = (original as NSString).range(of: "Second item")
        view.setAccessibilitySelectedTextRanges([NSValue(range: second), NSValue(range: first)])
        XCTAssertEqual(view.selectedPlainText, "First item\nSecond item")
        let capture = ShareCapture()
        view.delegate = capture
        view.orderFrontSharingServicePicker(nil)
        XCTAssertEqual(capture.items as? [String], ["First item\nSecond item"])
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.orderFrontSharingServicePicker(nil)
        XCTAssertEqual(capture.items as? [String], [original])
        XCTAssertEqual(capture.calls, 2)
        XCTAssertNil(view.window, "The delegate cancels presentation; no picker is shown")
    }

    func testHiddenProductionPanelInstallsOriginalExportersForValuesAndOrganizationNotes() throws {
        ApprovalCardFixtures.withLanguages { _ in
            for card in [ApprovalCardFixtures.Card.readDetails, .create, .organizeManyMoves] {
                var prompt = ApprovalCardFixtures.prompt(card)
                prompt.detailsExpanded = true
                let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in
                    NSRect(x: 0, y: 0, width: 1440, height: 900)
                })
                defer { panel.contentViewController = nil; panel.close() }
                for _ in 0..<5 {
                    panel.layoutIfNeeded()
                    panel.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                }
                var pending = panel.contentView.map { [$0] } ?? []
                var values: [ApprovalVariableLine.TextView] = []
                while let view = pending.popLast() {
                    if let value = view as? ApprovalVariableLine.TextView { values.append(value) }
                    pending += view.subviews
                }
                let expected = prompt.presentation.details.rows.flatMap { row -> [String] in
                    switch row.value {
                    case .text(let value): return [value]
                    case .lines(let lines): return lines.compactMap(\.note)
                    default: return []
                    }
                }
                XCTAssertFalse(expected.isEmpty)
                for original in expected {
                    guard let value = values.first(where: { $0.originalText == original }) else {
                        XCTFail("Missing original exporter for \(original)"); continue
                    }
                    assertExports(value, original: original)
                }
                XCTAssertFalse(panel.isVisible)
            }
        }
    }

    func testEmptyAndInvalidSelectionsNeverExportLayoutCharacters() {
        let view = ApprovalVariableLine.TextView()
        view.configure(ApprovalLine("“Staging API”"), textStyle: .details)
        view.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 7))
        let previous = view.selectedPlainText
        view.setAccessibilitySelectedTextRange(NSRange(location: Int.max, length: Int.max))
        XCTAssertEqual(view.selectedPlainText, previous)
        XCTAssertNil(view.accessibilityString(for: NSRange(location: Int.max, length: 1)))
        view.configure(ApprovalLine(""), textStyle: .details)
        XCTAssertEqual(view.selectedPlainText, "")
        XCTAssertEqual(view.accessibilityValue(), "")
    }

    private func assertExports(_ view: ApprovalVariableLine.TextView, original: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes), file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), original, file: file, line: line)
        XCTAssertNil(pasteboard.data(forType: .rtf), file: file, line: line)
        pasteboard.clearContents()
        XCTAssertTrue(view.writeSelection(to: pasteboard, type: .string), file: file, line: line)
        XCTAssertEqual(pasteboard.string(forType: .string), original, file: file, line: line)
        XCTAssertFalse(view.writeSelection(to: pasteboard, type: .rtf), file: file, line: line)
        XCTAssertEqual(view.accessibilityValue(), original, file: file, line: line)
        XCTAssertEqual(view.accessibilitySelectedText(), original, file: file, line: line)
    }

    private final class ShareCapture: NSObject, NSTextViewDelegate {
        var items: [Any] = []
        var calls = 0
        func textView(_ textView: NSTextView, willShow picker: NSSharingServicePicker, forItems items: [Any]) -> NSSharingServicePicker? {
            self.items = items
            calls += 1
            return nil
        }
    }
}
