import AppKit
import XCTest

/// Compares in-process renderings; never reads pixels from the screen.
struct NoticeRaster {
    let width: Int
    let height: Int
    let scale: CGFloat
    private let pixels: [UInt8]

    init(_ bitmap: NSBitmapImageRep) throws {
        let image = try XCTUnwrap(bitmap.cgImage)
        width = image.width
        height = image.height
        scale = CGFloat(width) / bitmap.size.width
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        pixels = bytes
    }

    func matchesPixel(x: Int, y: Int, other: Self, otherX: Int, otherY: Int) -> Bool {
        let offset = (y * width + x) * 4
        let otherOffset = (otherY * other.width + otherX) * 4
        for channel in 0..<4 {
            if abs(Int(pixels[offset + channel]) - Int(other.pixels[otherOffset + channel])) > 2 { return false }
        }
        return true
    }

    /// Returns window coordinates (origin at bottom left) only when the entire
    /// notice matches, including the last text line and the action button.
    func find(_ template: Self, atX pointX: CGFloat) -> CGRect? {
        guard scale == template.scale, template.height <= height else { return nil }
        let x = Int((pointX * scale).rounded())
        guard x >= 0, x + template.width <= width else { return nil }
        let probes = stride(from: 0, to: template.height, by: max(1, template.height / 8)).flatMap { row in
            stride(from: 0, to: template.width, by: max(1, template.width / 12)).map { (row, $0) }
        }
        for y in 0...(height - template.height) {
            guard probes.allSatisfy({ row, column in
                matchesPixel(x: x + column, y: y + row, other: template, otherX: column, otherY: row)
            }) else { continue }
            var matches = true
            for row in 0..<template.height {
                for column in 0..<template.width {
                    if !matchesPixel(x: x + column, y: y + row, other: template, otherX: column, otherY: row) {
                        matches = false
                        break
                    }
                }
                if !matches { break }
            }
            if matches {
                return CGRect(x: pointX, y: CGFloat(height - y - template.height) / scale,
                              width: CGFloat(template.width) / scale, height: CGFloat(template.height) / scale)
            }
        }
        return nil
    }
}
