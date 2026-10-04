import AppKit
import SwiftUI

func appLocalized(_ key: String, language: String? = nil) -> String {
    AppLanguage.localized(key, language: language ?? AppLanguage.current)
}

func appLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    let language = AppLanguage.current
    let format = AppLanguage.localized(key, language: language)
    return String(format: format, locale: AppLanguage.locale(for: language), arguments: arguments)
}

// MARK: - Theme

/// Design tokens for the v0.2 design language: three color roles (neutral,
/// accent, warning red), a five-size type scale plus monospace, 4-pt spacing
/// and three corner radii. Views take colors and fonts from here only.
enum Theme {
    static let controlHeight: CGFloat = 30
    static let rowHeight: CGFloat = 44
    static let tableHeaderHeight: CGFloat = 36

    // MARK: Neutral

    static let windowBackground = dynamic(light: 0xF6F6F4, dark: 0x0A0E13)
    static let sidebarBackground = dynamic(light: 0xECEEEC, dark: 0x13181D)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x13181D)
    static let text = dynamic(light: 0x1C1F23, dark: 0xF5F5F5)
    static let textSecondary = dynamic(light: 0x646B73, dark: 0xA0A0A0)
    static let textTertiary = dynamic(light: 0x8E949A, dark: 0x6B6B6B)
    static let separator = neutral(0.09)
    static let neutralSubtle = neutral(0.06)
    static let cardShadow = Color.black.opacity(0.08)

    // MARK: Accent

    /// The system accent color: the one primary action per view, toggles,
    /// links and positive states.
    static let accent = Color.accentColor
    static let accentSubtle = accent.opacity(0.12)
    /// Text and glyphs drawn on a filled accent or warning background.
    static let onAccent = Color.white

    // MARK: Warning

    /// Denied, failed, needs attention and irreversible actions.
    static let warning = dynamic(light: 0xC8342C, dark: 0xFF7B72)
    static let warningSubtle = warning.opacity(0.10)

    /// Neutral overlay: white-based in dark mode, black-based in light mode.
    static func neutral(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            (appearance.isDark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
        })
    }

    // MARK: Type

    /// The type scale. Text sizes come only from these steps; emphasis is
    /// `.weight(.semibold)` or `.bold()` on a step.
    enum Fonts {
        static let title = Font.system(size: 22, weight: .bold)
        static let headline = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 13)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        /// Commands, variable names and paths only.
        static let mono = Font.system(size: 12, design: .monospaced)
    }

    /// Sizes for standalone SF Symbol glyphs, which are not text.
    enum Icon {
        static let emptyState = Font.system(size: 32, weight: .light)
        static let lockedState = Font.system(size: 28, weight: .medium)
        static let inlineStatus = Font.system(size: 20)
        static let brandMark = Font.system(size: 20, weight: .bold)
    }

    // MARK: Layout

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 6
        static let group: CGFloat = 10
        static let alert: CGFloat = 13
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}


// MARK: - Shared control helpers

struct BorderedActionButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.secondaryAction)
    }
}
