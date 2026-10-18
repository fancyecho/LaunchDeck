// Renders the LaunchDeck app icon into build/AppIcon.iconset.
//   xcrun swift scripts/make-icon.swift "$PWD" && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
//
// A midnight glass squircle lit from the upper left, holding a 3×3 grid of glass
// tiles in a warm-to-cool spectrum around a glowing white centre tile, each tile
// casting a soft halo of its own colour.
import AppKit

func squircle(_ r: CGRect, exponent n: CGFloat = 4.6) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = r.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = r.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

func render(size: Int) -> CGImage {
    let S = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: S / 1024, y: S / 1024)  // draw in 1024-point space, y up
    ctx.interpolationQuality = .high

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body)

    // Drop shadow under the whole icon.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x10143A))
    ctx.fillPath()
    ctx.restoreGState()

    // Body: deep midnight gradient, light pooling from the upper left.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    linear(ctx, [color(0x2A3480), color(0x161B52), color(0x0A0D2A)], [0, 0.5, 1],
           from: CGPoint(x: 300, y: 924), to: CGPoint(x: 700, y: 100))
    radial(ctx, [color(0x8C9BFF, 0.5), color(0x8C9BFF, 0)], center: CGPoint(x: 250, y: 860), radius: 620)
    radial(ctx, [color(0xFF7AB6, 0.22), color(0xFF7AB6, 0)], center: CGPoint(x: 820, y: 230), radius: 460)

    // 3×3 glass tiles.
    let palette: [[UInt32]] = [
        [0xFF7A9C, 0xFF9E57, 0xFFD45C],
        [0xB08CFF, 0xFFFFFF, 0x5CD9C9],
        [0x6C8CFF, 0x4DB8FF, 0x59E3A2],
    ]
    let grid: CGFloat = 540, gap: CGFloat = 42
    let tile = (grid - gap * 2) / 3
    let origin = CGPoint(x: 512 - grid / 2, y: 512 - grid / 2)
    for row in 0..<3 {
        for col in 0..<3 {
            let hex = palette[row][col]
            let isCenter = row == 1 && col == 1
            let r = CGRect(x: origin.x + CGFloat(col) * (tile + gap),
                           y: origin.y + CGFloat(2 - row) * (tile + gap), width: tile, height: tile)
            let shape = squircle(r, exponent: 4.4)

            // Halo of the tile's own colour, diffusing onto the glass below.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: isCenter ? 70 : 46,
                          color: color(isCenter ? 0xBFD4FF : hex, isCenter ? 0.95 : 0.7))
            ctx.addPath(shape)
            ctx.setFillColor(color(hex, 0.9))
            ctx.fillPath()
            ctx.restoreGState()

            // Body: brighter at the top, the colour itself at the bottom.
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            let top = isCenter ? color(0xFFFFFF) : color(hex, 1).copy(alpha: 1)!
            linear(ctx, [isCenter ? color(0xFFFFFF) : blend(hex, 0xFFFFFF, 0.35), top,
                         isCenter ? color(0xD9E6FF) : blend(hex, 0x000000, 0.12)],
                   [0, 0.45, 1], from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY))
            // Glassy highlight across the upper part.
            linear(ctx, [color(0xFFFFFF, 0.5), color(0xFFFFFF, 0)], [0, 1],
                   from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.midY + tile * 0.05))
            ctx.restoreGState()

            // Hairline rim, bright on top.
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.setLineWidth(3)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            linear(ctx, [color(0xFFFFFF, 0.85), color(0xFFFFFF, 0.15)], [0, 1],
                   from: CGPoint(x: r.midX, y: r.maxY), to: CGPoint(x: r.midX, y: r.minY))
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    // Rim light around the whole icon: bright at the top, fading toward the bottom.
    ctx.saveGState()
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2)))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0.06), color(0xFFFFFF, 0.14)], [0, 0.6, 1],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    ctx.restoreGState()

    return ctx.makeImage()!
}

func blend(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xFF) / 255 }
    return CGColor(srgbRed: ch(a, 16) * (1 - t) + ch(b, 16) * t, green: ch(a, 8) * (1 - t) + ch(b, 8) * t,
                   blue: ch(a, 0) * (1 - t) + ch(b, 0) * t, alpha: 1)
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(size: base * scale))
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)
