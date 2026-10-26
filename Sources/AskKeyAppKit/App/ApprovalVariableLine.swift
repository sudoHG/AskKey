import AppKit
import SwiftUI

/// Break delivery variables after underscores while preserving the original
/// selected/copied and accessibility text, including partial selections.
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
        private let storage: NSTextStorage

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
                func insert(_ character: Character) {
                    displayed.append(character)
                    originalOffsets.append(originalOffset)
                }
                for character in segment.text {
                    // A word joiner prevents fallback character wrapping inside
                    // a variable token; a zero-width space allows an underscore break.
                    if segment.code, let previous, previous != "_" { insert("\u{2060}") }
                    displayed.append(character)
                    for _ in String(character).utf16 {
                        originalOffset += 1
                        originalOffsets.append(originalOffset)
                    }
                    if segment.code, character == "_" { insert("\u{200b}") }
                    previous = character
                }
                attributed.append(NSAttributedString(string: displayed, attributes: [
                    .font: segment.code ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ]))
            }
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
            let selection = selectedRange()
            guard selection.location != NSNotFound, NSMaxRange(selection) < originalOffsets.count else { return "" }
            let start = originalOffsets[selection.location]
            return (originalText as NSString).substring(with: NSRange(location: start,
                length: originalOffsets[NSMaxRange(selection)] - start))
        }

        override func copy(_ sender: Any?) {
            let text = selectedPlainText
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        override func accessibilityValue() -> String? { originalText }
        override func accessibilitySelectedText() -> String? { selectedPlainText }
        override func accessibilityNumberOfCharacters() -> Int { (originalText as NSString).length }
        override func accessibilityString(for range: NSRange) -> String? {
            guard range.location != NSNotFound, NSMaxRange(range) <= (originalText as NSString).length else { return nil }
            return (originalText as NSString).substring(with: range)
        }
        override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
            accessibilityString(for: range).map { NSAttributedString(string: $0) }
        }
    }
}
