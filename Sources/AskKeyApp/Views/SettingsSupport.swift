import AppKit
import SwiftUI
import AskKeyCore

func appLocalized(_ key: String, language: String? = nil) -> String {
    AppLanguage.localized(key, language: language ?? AppLanguage.current)
}

func appLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    let language = AppLanguage.current
    let format = AppLanguage.localized(key, language: language)
    return String(format: format, locale: AppLanguage.locale(for: language), arguments: arguments)
}

// MARK: - Theme

enum Theme {
    static let controlHeight: CGFloat = 30
    static let rowHeight: CGFloat = 44
    static let tableHeaderHeight: CGFloat = 36
    static let brand      = dynamic(light: (0.039, 0.424, 1.000), dark: (0.290, 0.620, 1.000))
    static let brandSubtle = brand.opacity(0.12)
    static let neutralSubtle = neutral(0.06)
    static let sep        = dynamic(light: (0.871, 0.886, 0.902), dark: (0.102, 0.129, 0.157))
    static let windowBackground = dynamic(light: (0.965, 0.965, 0.957), dark: (0.039, 0.055, 0.075))
    static let sidebarBackground = dynamic(light: (0.925, 0.933, 0.925), dark: (0.075, 0.094, 0.114))
    static let panelBackground = dynamic(light: (1.000, 1.000, 1.000), dark: (0.075, 0.094, 0.114))
    static let cardShadow = dynamic(light: (0.000, 0.000, 0.000), dark: (0.000, 0.000, 0.000)).opacity(0.08)
    static let text       = dynamic(light: (0.110, 0.122, 0.137), dark: (0.961, 0.961, 0.961))
    static let textMuted  = dynamic(light: (0.392, 0.420, 0.451), dark: (0.627, 0.627, 0.627))
    static let textDim    = dynamic(light: (0.557, 0.580, 0.604), dark: (0.420, 0.420, 0.420))
    static let bgHigh     = neutral(0.055)
    static let red        = dynamic(light: (0.788, 0.208, 0.165), dark: (1.000, 0.482, 0.447))
    static let green      = brand
    static let blue       = dynamic(light: (0.067, 0.408, 0.745), dark: (0.427, 0.686, 0.945))
    static let mint       = dynamic(light: (0.063, 0.522, 0.467), dark: (0.384, 0.824, 0.765))
    static let violet     = dynamic(light: (0.408, 0.310, 0.788), dark: (0.608, 0.529, 0.945))
    static let pink       = dynamic(light: (0.753, 0.224, 0.420), dark: (0.929, 0.522, 0.690))
    static let orange     = dynamic(light: (0.702, 0.522, 0.055), dark: (0.949, 0.800, 0.376))
    static let amber      = dynamic(light: (0.749, 0.420, 0.110), dark: (0.925, 0.635, 0.365))
    static let slate      = dynamic(light: (0.373, 0.435, 0.494), dark: (0.565, 0.624, 0.690))

    /// Contrast color for glyphs drawn on top of the accent colors above
    /// (light-mode accents are dark, dark-mode accents are pastel).
    static let onAccent   = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.72)
            : NSColor.white.withAlphaComponent(0.92)
    })

    /// Neutral overlay: white-based in dark mode, black-based in light mode.
    static func neutral(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            (appearance.isDark ? NSColor.white : NSColor.black).withAlphaComponent(opacity)
        })
    }

    private static func dynamic(
        light: (Double, Double, Double),
        dark: (Double, Double, Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.isDark ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
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
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(height: Theme.controlHeight)
                .padding(.horizontal, 10)
                .background(Theme.bgHigh, in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.sep, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
