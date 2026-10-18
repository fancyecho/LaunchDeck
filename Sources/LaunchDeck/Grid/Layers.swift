import AppKit
import QuartzCore

/// A layer with implicit animations switched off; every animation here is explicit.
class PlainLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

enum Motion {
    /// SwiftUI-style spring parameters mapped onto CASpringAnimation.
    static func spring(_ keyPath: String, from: Any?, to: Any?, response: CGFloat = 0.42,
                       damping: CGFloat = 0.86, velocity: CGFloat = 0) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.mass = 1
        a.stiffness = pow(2 * .pi / response, 2)
        a.damping = 4 * .pi * damping / response
        a.initialVelocity = velocity
        a.duration = a.settlingDuration
        return a
    }

    static func basic(_ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval,
                      timing: CAMediaTimingFunctionName = .easeOut) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: timing)
        return a
    }

    static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Springs `layer` to `position`, starting from wherever it currently appears.
    static func move(_ layer: CALayer, to position: CGPoint, response: CGFloat = 0.42, damping: CGFloat = 0.84) {
        let from = layer.presentation()?.position ?? layer.position
        layer.removeAnimation(forKey: "move")
        instantly { layer.position = position }
        guard hypot(from.x - position.x, from.y - position.y) > 0.5 else { return }
        layer.add(spring("position", from: NSValue(point: from), to: NSValue(point: position),
                         response: response, damping: damping), forKey: "move")
    }

    /// Springs a uniform scale, starting from the currently displayed scale.
    static func scale(_ layer: CALayer, to s: CGFloat, response: CGFloat = 0.36, damping: CGFloat = 0.7) {
        let from = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        layer.removeAnimation(forKey: "scale")
        instantly { layer.transform = CATransform3DMakeScale(s, s, 1) }
        guard abs(from - s) > 0.001 else { return }
        layer.add(spring("transform.scale", from: from, to: s, response: response, damping: damping), forKey: "scale")
    }

    /// Eased (non-spring) scale from the currently displayed value.
    static func scaleBasic(_ layer: CALayer, to s: CGFloat, duration: CFTimeInterval,
                           timing: CAMediaTimingFunctionName = .easeOut) {
        let from = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        layer.removeAnimation(forKey: "scale")
        instantly { layer.transform = CATransform3DMakeScale(s, s, 1) }
        layer.add(basic("transform.scale", from: from, to: s, duration: duration, timing: timing), forKey: "scale")
    }

    static func fade(_ layer: CALayer, to opacity: Float, duration: CFTimeInterval = 0.2) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        instantly { layer.opacity = opacity }
        guard abs(from - opacity) > 0.001 else { return }
        layer.add(basic("opacity", from: from, to: opacity, duration: duration), forKey: "fade")
    }
}

/// Bakes app names into bitmaps (text plus shadow) so moving hundreds of labels
/// costs the GPU nothing beyond compositing.
enum LabelRenderer {
    private static var cache: [String: CGImage] = [:]

    /// `badge` draws Launchpad's blue "new" dot before the name.
    static func image(_ text: String, fontSize: CGFloat, width: CGFloat, weight: NSFont.Weight = .medium,
                      scale: CGFloat = 2, badge: Bool = false) -> CGImage? {
        let key = "\(text)|\(fontSize)|\(width)|\(weight.rawValue)|\(scale)|\(badge)"
        if let hit = cache[key] { return hit }

        let height = ceil(fontSize * 1.45) + 4
        let px = (w: Int(ceil(width * scale)), h: Int(ceil(height * scale)))
        guard px.w > 0, px.h > 0,
              let ctx = CGContext(data: nil, width: px.w, height: px.h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attributed = NSMutableAttributedString()
        if badge {
            let dotFont = NSFont.systemFont(ofSize: fontSize * 0.62, weight: .bold)
            attributed.append(NSAttributedString(string: "\u{25CF}\u{2009}", attributes: [
                .font: dotFont,
                .foregroundColor: NSColor(srgbRed: 0.25, green: 0.6, blue: 1, alpha: 1),
                .paragraphStyle: paragraph,
                .baselineOffset: fontSize * 0.12,
            ]))
        }
        attributed.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ]))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(with: NSRect(x: 2, y: 2, width: width - 4, height: height - 4),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()

        let image = ctx.makeImage()
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = image
        return image
    }

    static func height(fontSize: CGFloat) -> CGFloat { ceil(fontSize * 1.45) + 4 }
}
