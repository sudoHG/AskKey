import AppKit

@MainActor
enum AppIcon {
    private static let mainBundleImage = load(bundle: .main)

    static func load() -> NSImage {
        mainBundleImage
    }

    /// Direct binary launches may give NSApplication a generic folder icon.
    static func load(
        bundle: Bundle,
        fallback: @MainActor () -> NSImage? = { NSApplication.shared.applicationIconImage }
    ) -> NSImage {
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return fallback() ?? NSImage()
    }
}
