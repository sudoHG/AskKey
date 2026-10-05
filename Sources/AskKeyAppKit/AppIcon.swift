import AppKit

@MainActor
enum AppIcon {
    /// Direct binary launches may give NSApplication a generic folder icon.
    static func load(
        bundle: Bundle = .main,
        fallback: @MainActor () -> NSImage? = { NSApplication.shared.applicationIconImage }
    ) -> NSImage {
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return fallback() ?? NSImage()
    }
}
