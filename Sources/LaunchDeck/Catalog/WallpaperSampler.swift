import AppKit

/// Low-resolution copy of the (already blurred) wallpaper for reading the colour
/// behind any point on screen.
struct WallpaperSampler {
    private let width = 64
    private let height = 40
    private var pixels: [UInt8]

    init?(image: CGImage) {
        var buffer = [UInt8](repeating: 0, count: 64 * 40 * 4)
        let ok: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 40))
            return true
        }
        guard ok else { return nil }
        pixels = buffer
    }

    /// Colour at `point` (y down) on a screen of `size`.
    func color(at point: CGPoint, in size: CGSize) -> NSColor {
        let x = min(max(Int(point.x / max(size.width, 1) * CGFloat(width)), 0), width - 1)
        let y = min(max(Int(point.y / max(size.height, 1) * CGFloat(height)), 0), height - 1)
        let i = (y * width + x) * 4  // row 0 is the top of the image
        return NSColor(srgbRed: CGFloat(pixels[i]) / 255, green: CGFloat(pixels[i + 1]) / 255,
                       blue: CGFloat(pixels[i + 2]) / 255, alpha: 1)
    }

    /// Frosted-glass body colour for a pane sitting over `point`: the wallpaper
    /// lifted toward white and made more vivid, at partial opacity.
    func glassTint(at point: CGPoint, in size: CGSize) -> CGColor {
        let base = color(at: point, in: size)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        let lifted = NSColor(hue: h, saturation: min(1, s * 1.15), brightness: min(1, v * 0.7 + 0.42), alpha: 1)
        // Fairly dense, so the pane reads as solid glass rather than a thin film.
        return lifted.withAlphaComponent(0.56).cgColor
    }
}
