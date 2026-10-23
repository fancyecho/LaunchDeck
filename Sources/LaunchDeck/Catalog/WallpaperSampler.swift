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
        // Mostly white frost with just a breath of the wallpaper's hue, so it reads
        // as clean glass over the scene rather than a tinted slab.
        let frost = NSColor(hue: h, saturation: min(0.22, s * 0.3), brightness: 1, alpha: 1)
        // Reduce Transparency: the same frost, but solid enough that the wallpaper
        // no longer shows through behind the mini icons.
        if DisplayOptions.reduceTransparency {
            return NSColor(hue: h, saturation: min(0.18, s * 0.25), brightness: 0.86, alpha: 0.92).cgColor
        }
        return frost.withAlphaComponent(0.3).cgColor
    }
}
