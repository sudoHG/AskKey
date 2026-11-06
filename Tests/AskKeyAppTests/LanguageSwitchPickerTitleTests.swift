import AppKit
import SwiftUI
import XCTest
@testable import AskKeyAppKit

/// A language switch changes every picker item's title but not the selection.
/// The displayed title must still follow the switch (#266). SwiftUI draws
/// these pickers itself on current macOS, so the test compares what is drawn:
/// a page switched to English must look exactly like a page opened in English.
@MainActor
final class LanguageSwitchPickerTitleTests: AppLanguageExperienceTestSupport {
    override func tearDown() {
        AppLanguage.apply(mode: "en")
        super.tearDown()
    }

    func testSettingsPickersShowTheNewLanguageAfterASwitch() throws {
        let vault = makeViewModel(preferences: AppPreferences(defaults: defaults), login: LoginItemProbe())
        // Selections whose titles are translated: 30 minutes and Off.
        vault.hotkeyShortcutID = "disabled"
        vault.languageMode = "zh-Hans"
        let switched = host(FrozenSettingsPage().environment(vault))
        let chinese = try render(switched)

        vault.languageMode = "en"
        let afterSwitch = try render(switched)
        let openedInEnglish = try render(host(FrozenSettingsPage().environment(vault)))

        XCTAssertNotEqual(chinese, afterSwitch, "the page must redraw on a language switch")
        XCTAssertEqual(
            afterSwitch, openedInEnglish,
            "a picker kept the previous language's title after the switch"
        )
    }

    private func host<V: View>(_ view: V) -> NSHostingView<some View> {
        _ = NSApplication.shared
        let size = CGSize(width: 760, height: 1200)
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        return hosting
    }

    private func render(_ hosting: NSView) throws -> Data {
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        let representation = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}
