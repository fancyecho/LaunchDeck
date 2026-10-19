// Writes the LaunchDeck app icon as an Icon Composer document,
// Resources/AppIcon.icon. Run scripts/make-icon.sh, which also renders the
// fallback .icns and the README image from it.
//
// Design: a glass comet streaking up across a twilight sky. The sky (fill plus a
// pre-blurred PNG with the horizon glow, star dust and the comet's soft, feathered
// tail of light) is the hero; the comet head is a Liquid Glass layer on top, so it
// refracts the sky and catches the system's specular light.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let doc = root.appendingPathComponent("Resources/AppIcon.icon")
let assets = doc.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: doc)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// MARK: - Geometry (1024-point canvas, y down as in SVG)

let head = CGPoint(x: 668, y: 346)
let headRadius: CGFloat = 126
let tip = CGPoint(x: 182, y: 848)

/// The tail outline: leaves the head at its two tangents, bows gently toward the
/// lower right (a rising trajectory) and tapers to `tip`.
func tailPath(widthScale: CGFloat = 0.92, bow: CGFloat = 70) -> CGPath {
    let dx = tip.x - head.x, dy = tip.y - head.y
    let len = hypot(dx, dy)
    let n = CGPoint(x: -dy / len, y: dx / len)  // left-hand normal
    let w = headRadius * widthScale
    let a = CGPoint(x: head.x + n.x * w, y: head.y + n.y * w)
    let b = CGPoint(x: head.x - n.x * w, y: head.y - n.y * w)
    // Shared bow direction (toward lower right = -n here), stronger on the outer edge.
    func ctrl(_ t: CGFloat, _ side: CGFloat, _ spread: CGFloat) -> CGPoint {
        CGPoint(x: head.x + dx * t + n.x * (side * spread - bow), y: head.y + dy * t + n.y * (side * spread - bow))
    }
    let p = CGMutablePath()
    p.move(to: a)
    p.addCurve(to: tip, control1: ctrl(0.3, 1, w * 0.9), control2: ctrl(0.7, 1, w * 0.25))
    p.addCurve(to: b, control1: ctrl(0.7, -1, w * 0.2), control2: ctrl(0.3, -1, w * 0.85))
    p.addArc(center: head, radius: w, startAngle: atan2(b.y - head.y, b.x - head.x),
             endAngle: atan2(a.y - head.y, a.x - head.x), clockwise: false)
    p.closeSubpath()
    return p
}

// MARK: - SVG layers

func svgPath(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += String(format: "M%.1f,%.1f ", p[0].x, p[0].y)
        case .addLineToPoint: d += String(format: "L%.1f,%.1f ", p[0].x, p[0].y)
        case .addQuadCurveToPoint: d += String(format: "Q%.1f,%.1f %.1f,%.1f ", p[0].x, p[0].y, p[1].x, p[1].y)
        case .addCurveToPoint:
            d += String(format: "C%.1f,%.1f %.1f,%.1f %.1f,%.1f ", p[0].x, p[0].y, p[1].x, p[1].y, p[2].x, p[2].y)
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d
}

func svg(_ body: String, defs: String = "") -> String {
    #"<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>"#
        + defs + "</defs>" + body + "</svg>"
}

// Head: lit from the upper right, cooling to lavender on the far side, so the
// glass reads as a sphere rather than a flat disc.
let headDefs = ##"<radialGradient id="h" cx="0.68" cy="0.3" r="0.85">"##
    + ##"<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.55" stop-color="#F1F3FF"/>"##
    + ##"<stop offset="1" stop-color="#C9C6F2"/></radialGradient>"##
try! svg(String(format: ##"<circle cx="%.1f" cy="%.1f" r="%.1f" fill="url(#h)"/>"##, head.x, head.y, headRadius),
         defs: headDefs)
    .write(to: assets.appendingPathComponent("head.svg"), atomically: true, encoding: .utf8)

// MARK: - Sky PNG (soft light that glass can't do: glows, haze, stars)

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func radial(_ ctx: CGContext, _ stops: [(CGFloat, CGColor)], at c: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
                       locations: stops.map(\.0))!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
}

/// Fills `path` blurred by `blur`, using the off-canvas shadow trick.
func blurred(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, blur: CGFloat) {
    let off: CGFloat = 4000
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: off, height: 0), blur: blur, color: color)
    ctx.translateBy(x: -off, y: 0)
    ctx.addPath(path)
    ctx.setFillColor(srgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}

let px = 1024
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in the same y-down space as the SVGs.
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)

// Warm horizon glow rising from the lower left, fading through rose into the night.
radial(ctx, [(0, srgb(0xFFA486, 0.9)), (0.35, srgb(0xF0789C, 0.45)), (0.7, srgb(0xB062C8, 0.12)), (1, srgb(0xB062C8, 0))],
       at: CGPoint(x: 60, y: 1080), radius: 900)
// A faint cool band of light across the top, like the last of the day.
radial(ctx, [(0, srgb(0x6F86FF, 0.28)), (1, srgb(0x6F86FF, 0))], at: CGPoint(x: 900, y: -60), radius: 640)

// Star dust, kept away from the comet's path.
var seed: UInt64 = 0x1D_EC_0A_55
func rand() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat((seed >> 33) % 100_000) / 100_000
}
let tailHit = tailPath(widthScale: 1.6, bow: 70)
var placed = 0
while placed < 26 {
    let p = CGPoint(x: 60 + rand() * 904, y: 60 + rand() * 820)
    let size = 1.6 + pow(rand(), 3) * 4.2
    let alpha = 0.25 + rand() * 0.6
    if tailHit.contains(p) || hypot(p.x - head.x, p.y - head.y) < headRadius * 2.1 { continue }
    placed += 1
    radial(ctx, [(0, srgb(0xFFFFFF, alpha)), (0.4, srgb(0xEAF0FF, alpha * 0.5)), (1, srgb(0xEAF0FF, 0))],
           at: p, radius: size * 2.4)
}

// The comet's light in the sky: a halo round the head, then the tail.
radial(ctx, [(0, srgb(0xEEF3FF, 0.55)), (0.45, srgb(0xC9D7FF, 0.2)), (1, srgb(0xC9D7FF, 0))],
       at: head, radius: headRadius * 3)

// Tail: a wide haze, a softer body and a brighter core, all feathered, then
// faded out toward the tip so it dissolves into the sky with no hard edge.
let tailLayer = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
tailLayer.translateBy(x: 0, y: 1024)
tailLayer.scaleBy(x: 1, y: -1)
blurred(tailLayer, tailPath(widthScale: 1.35, bow: 80), srgb(0xD6E2FF, 0.42), blur: 50)
blurred(tailLayer, tailPath(widthScale: 1.0, bow: 70), srgb(0xF2F6FF, 0.6), blur: 18)
blurred(tailLayer, tailPath(widthScale: 0.72, bow: 64), srgb(0xFFFFFF, 0.8), blur: 9)
tailLayer.setBlendMode(.destinationIn)
let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [srgb(0xFFFFFF, 1), srgb(0xFFFFFF, 0.55), srgb(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 0.4, 1])!
tailLayer.drawLinearGradient(fade, start: head, end: tip, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Undo the y flip while compositing, or the bitmap lands upside down.
ctx.saveGState()
ctx.translateBy(x: 0, y: 1024)
ctx.scaleBy(x: 1, y: -1)
ctx.draw(tailLayer.makeImage()!, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
ctx.restoreGState()

let sky = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! sky.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("sky.png"))

// MARK: - icon.json

func p3(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> String {
    String(format: "display-p3:%.3f,%.3f,%.3f,%.3f", r, g, b, a)
}

/// Keeps a glass layer bright white in Dark mode too, where the system would
/// otherwise tint it toward the dark fill.
func whiteGlass(_ name: String, _ image: String) -> [String: Any] {
    ["name": name, "image-name": image, "glass": true,
     "fill-specializations": [["appearance": "dark", "value": ["solid": p3(0.92, 0.94, 1)]]]]
}

let icon: [String: Any] = [
    "fill": ["linear-gradient": [p3(0.075, 0.085, 0.25), p3(0.30, 0.19, 0.50)]],
    "groups": [
        ["layers": [whiteGlass("head", "head.svg")],
         "shadow": ["kind": "layer-color", "opacity": 0.55],
         "translucency": ["enabled": true, "value": 0.25],
         "specular": true, "lighting": "individual"],
        ["layers": [["name": "sky", "image-name": "sky.png", "glass": false]],
         "shadow": ["kind": "none", "opacity": 0],
         "translucency": ["enabled": false, "value": 0],
         "specular": false, "lighting": "combined"],
    ],
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]
let json = try! JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: doc.appendingPathComponent("icon.json"))
print(doc.path)
