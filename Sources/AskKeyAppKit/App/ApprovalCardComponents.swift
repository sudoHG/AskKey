import AppKit
import SwiftUI

/// A fixed card section: its heading, an optional status tag and trailing
/// control, then content. The overflow line names it while it is hidden.
struct ApprovalSection<Content: View, Accessory: View>: View {
    let title: String
    let tag: ApprovalTag?
    let name: String?
    let identifier: String
    let accessory: Accessory
    let content: Content

    init(title: String, tag: ApprovalTag? = nil, name: String? = nil, identifier: String,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tag = tag
        self.name = name
        self.identifier = identifier
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(verbatim: title)
                    .font(Theme.Fonts.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let tag { ApprovalTagView(tag: tag) }
                Spacer(minLength: Theme.Spacing.sm)
                accessory
            }
            content
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.text)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .approvalScrollMarker(name: name ?? title)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

extension ApprovalSection where Accessory == EmptyView {
    init(title: String, tag: ApprovalTag? = nil, name: String? = nil, identifier: String,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, tag: tag, name: name, identifier: identifier, accessory: { EmptyView() }, content: content)
    }
}

struct ApprovalTagView: View {
    let tag: ApprovalTag

    var body: some View {
        Text(verbatim: tag.title)
            .font(Theme.Fonts.caption.weight(.semibold))
            .foregroundStyle(tag.color)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Spacing.xs))
            .fixedSize()
    }
}

extension ApprovalTag {
    /// Grey for no change, blue for edits, green for additions, orange for
    /// replaced values and merges, red for removals; new groups stay neutral.
    var color: Color {
        switch self {
        case .unchanged, .noChange: return Theme.textSecondary
        case .changed: return ApprovalTagPalette.blue
        case .new: return ApprovalTagPalette.green
        case .newGroup: return Theme.text
        case .replaced, .merge: return ApprovalTagPalette.orange
        case .removed: return Theme.warning
        }
    }
}

private enum ApprovalTagPalette {
    static let blue = dynamic(light: 0x0A60C2, dark: 0x6CB6FF)
    static let green = dynamic(light: 0x1B7F3B, dark: 0x5FD38A)
    static let orange = dynamic(light: 0xB35300, dark: 0xFFA657)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Card text whose variable names render in the monospaced face. A status
/// tag leads the first line and the text wraps under it at full width.
struct ApprovalLineText: View {
    let line: ApprovalLine
    var tag: ApprovalTag?

    var body: some View {
        Text(attributed)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        if let tag {
            var label = AttributedString("\u{2009}" + tag.title + "\u{2009}")
            label.font = Theme.Fonts.caption.weight(.semibold)
            label.foregroundColor = tag.color
            label.backgroundColor = Theme.neutralSubtle
            result += label + AttributedString(" ")
        }
        for segment in line.segments {
            var part = AttributedString(segment.text)
            if segment.code { part.font = Theme.Fonts.mono }
            result += part
        }
        return result
    }
}

enum ApprovalButtonRole: Equatable {
    case primary, secondary, destructive
}

/// Full-width stacked alert button: the one filled accent action, a white
/// bordered secondary action, or a bordered red action whose effect is hard
/// to undo. "Deny" is secondary, never red.
struct ApprovalPromptButton: View {
    let title: String
    let role: ApprovalButtonRole
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.controlHeight)
                .background(role == .primary ? Theme.accent : Theme.surface, in: .rect(cornerRadius: Theme.Radius.control))
                .overlay {
                    if role != .primary {
                        RoundedRectangle(cornerRadius: Theme.Radius.control)
                            .stroke(role == .destructive ? Theme.warning.opacity(0.45) : Theme.separator)
                    }
                }
                .shadow(color: Theme.cardShadow, radius: 1, y: 0.5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color {
        switch role {
        case .primary: return Theme.onAccent
        case .secondary: return Theme.text
        case .destructive: return Theme.warning
        }
    }
}
