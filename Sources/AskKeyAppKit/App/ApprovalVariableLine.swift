import AppKit
import SwiftUI

/// Prefer underscore breaks, with a fallback for long words. All text exports
/// and accessibility keep the original text, including partial selections.
struct ApprovalVariableLine: NSViewRepresentable {
    let line: ApprovalLine

    func makeNSView(context: Context) -> TextView { TextView() }

    func updateNSView(_ view: TextView, context: Context) { view.configure(line) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> CGSize? {
        nsView.measuredSize(width: proposal.width ?? FrozenAgentApprovalPrompt.contentWidth)
    }

    final class TextView: NSTextView {
        private(set) var originalText = ""
        private var originalOffsets = [0]
        private var displayOffsets = [0]
        private let storage: NSTextStorage
        private var sharingPicker: NSSharingServicePicker?

        init() {
            let storage = NSTextStorage()
            self.storage = storage
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            super.init(frame: .zero, textContainer: container)
            isEditable = false
            isSelectable = true
            drawsBackground = false
            textContainerInset = .zero
            textContainer?.lineFragmentPadding = 0
            isHorizontallyResizable = false
            isVerticallyResizable = true
            focusRingType = .none
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(_ line: ApprovalLine) {
            originalText = line.plainText
            originalOffsets = [0]
            var originalOffset = 0
            let attributed = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.hyphenationFactor = 0
            for segment in line.segments {
                var displayed = ""
                var previous: Character?
                var wordLength = 0
                func insert(_ character: Character) {
                    displayed.append(character)
                    originalOffsets.append(originalOffset)
                }
                for character in segment.text {
                    if segment.code, let previous, previous != "_" {
                        if wordLength == 12 {
                            insert("\u{200b}")
                            wordLength = 0
                        } else { insert("\u{2060}") }
                    }
                    displayed.append(character)
                    for _ in String(character).utf16 {
                        originalOffset += 1
                        originalOffsets.append(originalOffset)
                    }
                    if segment.code, character == "_" { insert("\u{200b}") }
                    wordLength = character == "_" ? 0 : wordLength + 1
                    previous = character
                }
                attributed.append(NSAttributedString(string: displayed, attributes: [
                    .font: segment.code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ]))
            }
            displayOffsets = Array(repeating: 0, count: originalOffset + 1)
            for (display, original) in originalOffsets.enumerated() { displayOffsets[original] = display }
            textStorage?.setAttributedString(attributed)
            invalidateIntrinsicContentSize()
        }

        func measuredSize(width: CGFloat) -> CGSize {
            let width = max(1, width)
            textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            guard let layoutManager, let textContainer else { return CGSize(width: width, height: 0) }
            layoutManager.ensureLayout(for: textContainer)
            return CGSize(width: width, height: ceil(layoutManager.usedRect(for: textContainer).height))
        }

        var selectedPlainText: String {
            selectedOriginalRanges.filter { $0.length > 0 }
                .map { (originalText as NSString).substring(with: $0) }.joined(separator: "\n")
        }

        private var selectedOriginalRanges: [NSRange] {
            selectedRanges.compactMap { originalRange($0.rangeValue) }.sorted { $0.location < $1.location }
        }

        // All offsets are UTF-16. Only generated controls collapse; identical
        // zero-width characters already present in the original are preserved.
        private func translatedRange(_ range: NSRange, offsets: [Int]) -> NSRange? {
            guard range.location >= 0, range.location < offsets.count, range.length >= 0,
                  range.length < offsets.count - range.location else { return nil }
            let start = offsets[range.location]
            return NSRange(location: start, length: offsets[range.location + range.length] - start)
        }

        private func originalRange(_ range: NSRange) -> NSRange? {
            translatedRange(range, offsets: originalOffsets)
        }

        private func displayRange(_ range: NSRange) -> NSRange? {
            translatedRange(range, offsets: displayOffsets)
        }

        override func copy(_ sender: Any?) {
            _ = writeSelection(to: .general, types: writablePasteboardTypes)
        }

        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

        // NSTextView uses this for Copy, dragging and Services. Never export
        // rich text containing the inserted layout controls.
        override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard type == .string, !selectedPlainText.isEmpty else { return false }
            return pboard.setString(selectedPlainText, forType: .string)
        }

        private func exportFindSelection(_ sender: Any?) -> Bool {
            let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag
            guard tag == NSTextFinder.Action.setSearchString.rawValue else { return false }
            if !selectedPlainText.isEmpty {
                let pasteboard = NSPasteboard(name: .find)
                pasteboard.addTypes([.string], owner: nil)
                pasteboard.setString(selectedPlainText, forType: .string)
            }
            return true
        }

        override func performFindPanelAction(_ sender: Any?) {
            if !exportFindSelection(sender) { super.performFindPanelAction(sender) }
        }

        override func performTextFinderAction(_ sender: Any?) {
            if !exportFindSelection(sender) { super.performTextFinderAction(sender) }
        }

        override func orderFrontSharingServicePicker(_ sender: Any?) {
            let hasSelection = selectedRanges.contains { $0.rangeValue.length > 0 }
            let text = hasSelection ? selectedPlainText : originalText
            guard !text.isEmpty else { return }
            let items = [text]
            let picker = NSSharingServicePicker(items: items)
            if let delegate, delegate.responds(to: #selector(NSTextViewDelegate.textView(_:willShow:forItems:))) {
                guard let customized = delegate.textView?(self, willShow: picker, forItems: items) else { return }
                sharingPicker = customized
            } else {
                sharingPicker = picker
            }
            sharingPicker?.delegate = delegate as? NSSharingServicePickerDelegate
            sharingPicker?.show(relativeTo: visibleRect, of: self, preferredEdge: .minY)
        }

        override func accessibilityValue() -> String? { originalText }
        override func accessibilitySelectedText() -> String? { selectedPlainText }
        override func accessibilityNumberOfCharacters() -> Int { (originalText as NSString).length }
        override func accessibilitySelectedTextRange() -> NSRange {
            selectedOriginalRanges.first ?? NSRange(location: NSNotFound, length: 0)
        }
        override func accessibilitySelectedTextRanges() -> [NSValue]? {
            selectedOriginalRanges.map { NSValue(range: $0) }
        }
        override func setAccessibilitySelectedTextRange(_ range: NSRange) {
            guard let displayed = displayRange(range) else { return }
            setSelectedRange(displayed)
        }
        override func setAccessibilitySelectedTextRanges(_ ranges: [NSValue]?) {
            guard let ranges, !ranges.isEmpty else { return }
            let displayed = ranges.compactMap { displayRange($0.rangeValue) }
            guard displayed.count == ranges.count else { return }
            selectedRanges = displayed.map { NSValue(range: $0) }
        }
        override func accessibilityString(for range: NSRange) -> String? {
            guard displayRange(range) != nil else { return nil }
            return (originalText as NSString).substring(with: range)
        }
        override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
            accessibilityString(for: range).map { NSAttributedString(string: $0) }
        }
        override func accessibilityRTF(for range: NSRange) -> Data? {
            guard let text = accessibilityAttributedString(for: range) else { return nil }
            return try? text.data(from: NSRange(location: 0, length: text.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        override func accessibilityRange(for index: Int) -> NSRange {
            guard index >= 0, index < (originalText as NSString).length else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return (originalText as NSString).rangeOfComposedCharacterSequence(at: index)
        }
        override func accessibilityStyleRange(for index: Int) -> NSRange {
            guard index >= 0, index < displayOffsets.count - 1 else { return NSRange(location: NSNotFound, length: 0) }
            var range = NSRange()
            _ = storage.attributes(at: displayOffsets[index], effectiveRange: &range)
            return originalRange(range) ?? NSRange(location: NSNotFound, length: 0)
        }

        private var displayLineRanges: [NSRange] {
            guard let layoutManager, let textContainer else { return [] }
            layoutManager.ensureLayout(for: textContainer)
            var ranges: [NSRange] = []
            layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) {
                _, _, _, glyphs, _ in
                ranges.append(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            if layoutManager.extraLineFragmentTextContainer != nil {
                ranges.append(NSRange(location: storage.length, length: 0))
            }
            return ranges
        }

        override func accessibilityRange(forLine line: Int) -> NSRange {
            let ranges = displayLineRanges
            guard ranges.indices.contains(line), let range = originalRange(ranges[line]) else {
                return NSRange(location: NSNotFound, length: 0)
            }
            return range
        }
        override func accessibilityLine(for index: Int) -> Int {
            guard index >= 0, index < displayOffsets.count else { return NSNotFound }
            let displayed = displayOffsets[index]
            let ranges = displayLineRanges
            return ranges.firstIndex { NSLocationInRange(displayed, $0) }
                ?? (index == displayOffsets.count - 1 && !ranges.isEmpty ? ranges.count - 1 : NSNotFound)
        }
        override func accessibilityInsertionPointLineNumber() -> Int {
            accessibilityLine(for: accessibilitySelectedTextRange().location)
        }
        override func accessibilityVisibleCharacterRange() -> NSRange {
            guard let layoutManager, let textContainer else { return NSRange(location: NSNotFound, length: 0) }
            let rect = visibleRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
            let glyphs = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
            return originalRange(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
                ?? NSRange(location: NSNotFound, length: 0)
        }
        override func accessibilitySharedCharacterRange() -> NSRange {
            NSRange(location: 0, length: (originalText as NSString).length)
        }
        override func accessibilityFrame(for range: NSRange) -> NSRect {
            guard let displayed = displayRange(range), let layoutManager, let textContainer, let window else { return .zero }
            if displayed.length == 0 { return firstRect(forCharacterRange: displayed, actualRange: nil) }
            let glyphs = layoutManager.glyphRange(forCharacterRange: displayed, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            return window.convertToScreen(convert(rect, to: nil))
        }
        override func accessibilityRange(for position: NSPoint) -> NSRange {
            guard let layoutManager, let textContainer, let window else { return NSRange(location: NSNotFound, length: 0) }
            let local = convert(window.convertPoint(fromScreen: position), from: nil)
            let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
            let displayed = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            guard displayed < originalOffsets.count else { return NSRange(location: NSNotFound, length: 0) }
            return accessibilityRange(for: originalOffsets[displayed])
        }
    }
}
