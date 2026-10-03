import AppKit
import SwiftUI

struct MenuBarIcon: View {
    var body: some View {
        Image(nsImage: Self.templateImage())
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .foregroundStyle(.primary)
    }

    static func templateImage(size: CGFloat = 18) -> NSImage {
        let artwork = Self.packagedArtwork
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    static func artwork(in bundle: Bundle) -> NSImage? {
        bundle.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
    }

    private static let packagedArtwork = artwork(in: .main)
        ?? NSImage(size: NSSize(width: 18, height: 18))
}
