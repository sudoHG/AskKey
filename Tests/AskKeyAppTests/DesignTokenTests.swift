import XCTest
import AppKit
import SwiftUI
@testable import AskKeyAppKit

final class DesignTokenTests: XCTestCase {
    func testNeutralAndWarningRolesResolveToTheContractInLightMode() {
        let expected: [(Color, String)] = [
            (Theme.windowBackground, WorkspaceVisualContract.windowBackgroundHex),
            (Theme.sidebarBackground, WorkspaceVisualContract.sidebarBackgroundHex),
            (Theme.surface, WorkspaceVisualContract.surfaceHex),
            (Theme.text, WorkspaceVisualContract.textHex),
            (Theme.textSecondary, WorkspaceVisualContract.textSecondaryHex),
            (Theme.textTertiary, WorkspaceVisualContract.textTertiaryHex),
            (Theme.warning, WorkspaceVisualContract.warningHex),
        ]
        for (color, hex) in expected {
            XCTAssertEqual(resolved(color, .aqua).hex, hex)
        }
        let separator = resolved(Theme.separator, .aqua)
        XCTAssertEqual(separator.hex, "000000")
        XCTAssertEqual(separator.alpha, WorkspaceVisualContract.separatorOpacity, accuracy: 0.001)
    }

    func testDarkModeKeepsTheSameRolesWithReadableValues() {
        XCTAssertEqual(resolved(Theme.windowBackground, .darkAqua).hex, "0A0E13")
        XCTAssertEqual(resolved(Theme.text, .darkAqua).hex, "F5F5F5")
        XCTAssertEqual(resolved(Theme.warning, .darkAqua).hex, "FF7B72")
        XCTAssertEqual(resolved(Theme.separator, .darkAqua).hex, "FFFFFF")
    }

    func testAccentIsTheSystemAccentColor() {
        XCTAssertEqual(Theme.accent, Color.accentColor)
    }

    func testTypeScaleHasFiveSizesPlusMonospace() {
        let scale = WorkspaceVisualContract.typeScale
        XCTAssertEqual(scale, [22, 15, 13, 12, 11])
        XCTAssertEqual(Theme.Fonts.title, .system(size: scale[0], weight: .bold))
        XCTAssertEqual(Theme.Fonts.headline, .system(size: scale[1], weight: .semibold))
        XCTAssertEqual(Theme.Fonts.body, .system(size: scale[2]))
        XCTAssertEqual(Theme.Fonts.secondary, .system(size: scale[3]))
        XCTAssertEqual(Theme.Fonts.caption, .system(size: scale[4]))
        XCTAssertEqual(
            Theme.Fonts.mono,
            .system(size: WorkspaceVisualContract.monospaceSize, design: .monospaced)
        )
    }

    func testSpacingAndRadiusFollowTheFourPointGrid() {
        XCTAssertEqual(
            [Theme.Spacing.xs, Theme.Spacing.sm, Theme.Spacing.md,
             Theme.Spacing.lg, Theme.Spacing.xl, Theme.Spacing.xxl].map(Double.init),
            WorkspaceVisualContract.spacingScale
        )
        XCTAssertEqual(
            [Theme.Radius.control, Theme.Radius.group, Theme.Radius.alert].map(Double.init),
            WorkspaceVisualContract.radii
        )
    }

    private func resolved(_ color: Color, _ name: NSAppearance.Name) -> (hex: String, alpha: Double) {
        var result = (hex: "", alpha: 0.0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            result.hex = channels.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
            result.alpha = Double(rgb.alphaComponent)
        }
        return result
    }
}
