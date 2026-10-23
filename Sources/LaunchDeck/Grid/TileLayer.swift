import AppKit
import QuartzCore

/// One grid cell: an app icon or a folder (a pane of tinted glass holding mini
/// icons) with its name underneath. Static parts are bitmaps; the light effects
/// (hover tilt, specular highlight, colour glow, rim light) are cheap layer moves.
final class TileLayer: PlainLayer {
    enum Content: Equatable {
        case app(icon: CGImage?)
        case folder(icons: [CGImage?])

        static func == (a: Content, b: Content) -> Bool {
            switch (a, b) {
            case (.app(let x), .app(let y)): return x === y
            case (.folder(let x), .folder(let y)):
                return x.count == y.count && zip(x, y).allSatisfy { $0 === $1 }
            default: return false
            }
        }
    }

    private(set) var itemID: String = ""
    /// Tilts in 3D toward the pointer; holds the icon.
    let iconHost = PlainLayer()
    /// The icon itself (scaled on press, carries the drop shadow).
    let iconLayer = PlainLayer()
    let labelLayer = PlainLayer()
    let highlightLayer = PlainLayer()

    /// Soft halo in the icon's own colour that blooms underneath on hover.
    private let glowLayer = CAGradientLayer()
    /// Specular highlight that follows the pointer across the icon surface.
    private let specularHolder = PlainLayer()
    private let specularMask = PlainLayer()
    private let specular = CAGradientLayer()

    // Folder glass.
    private let folderBackground = PlainLayer()
    private let folderSheen = CAGradientLayer()
    /// Darkens the bottom of the folder glass a touch, giving the pane thickness.
    private let folderDepth = CAGradientLayer()
    /// Light caught inside the top edge, shade inside the bottom: the glass's thickness.
    private let folderBevel = CAGradientLayer()
    private let folderBevelMask = PlainLayer()
    private static let restingShadow: Float = 0.18
    private let folderRim = CAGradientLayer()
    private let folderRimMask = PlainLayer()
    private var miniLayers: [PlainLayer] = []
    /// Dock-style dot under apps that are currently running.
    private let runningDot = PlainLayer()

    private var content: Content?
    private var label = ""
    private var badge = false
    private(set) var glowColor: CGColor?
    private var appliedMetrics: GridMetrics?
    private var hovering = false

    init(itemID: String) {
        self.itemID = itemID
        super.init()
        for l in [glowLayer, specular, folderSheen, folderDepth, folderRim] as [CALayer] { l.actions = Self.noActions }
        folderDepth.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.05).cgColor]
        folderDepth.locations = [0.5, 1]
        folderBevel.actions = Self.noActions
        folderBevel.colors = [NSColor.white.withAlphaComponent(0.38).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
                              NSColor.black.withAlphaComponent(0.12).cgColor]
        folderBevel.locations = [0, 0.45, 1]
        folderBevelMask.borderColor = NSColor.black.cgColor
        folderBevelMask.cornerCurve = .continuous
        folderBevel.mask = folderBevelMask
        folderDepth.cornerCurve = .continuous
        folderDepth.masksToBounds = true

        glowLayer.type = .radial
        glowLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        glowLayer.endPoint = CGPoint(x: 1, y: 1)
        glowLayer.opacity = 0

        addSublayer(highlightLayer)
        addSublayer(glowLayer)
        addSublayer(iconHost)
        iconHost.addSublayer(iconLayer)
        addSublayer(labelLayer)
        addSublayer(runningDot)
        runningDot.backgroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        runningDot.shadowColor = NSColor.white.cgColor
        runningDot.shadowOpacity = 0.9
        runningDot.shadowRadius = 3
        runningDot.shadowOffset = .zero
        runningDot.opacity = 0

        highlightLayer.opacity = 0
        highlightLayer.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        highlightLayer.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        highlightLayer.borderWidth = 1
        highlightLayer.cornerCurve = .continuous
        iconLayer.contentsGravity = .resizeAspect
        labelLayer.contentsGravity = .resize
        iconLayer.shadowColor = NSColor.black.cgColor
        iconLayer.shadowOpacity = Self.restingShadow

        specular.type = .radial
        specular.startPoint = CGPoint(x: 0.5, y: 0.5)
        specular.endPoint = CGPoint(x: 1, y: 1)
        specular.colors = [NSColor.white.withAlphaComponent(0.32).cgColor,
                           NSColor.white.withAlphaComponent(0.08).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor]
        specular.locations = [0, 0.4, 1]
        specularMask.contentsGravity = .resizeAspect
        specularHolder.mask = specularMask
        specularHolder.addSublayer(specular)
        specularHolder.opacity = 0

        folderBackground.cornerCurve = .continuous
        folderBackground.masksToBounds = false
        folderBackground.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        folderSheen.colors = [NSColor.white.withAlphaComponent(0.2).cgColor,
                              NSColor.white.withAlphaComponent(0.04).cgColor,
                              NSColor.white.withAlphaComponent(0).cgColor]
        folderSheen.locations = [0, 0.45, 1]
        folderSheen.cornerCurve = .continuous
        folderSheen.masksToBounds = true
        folderRimMask.borderColor = NSColor.black.cgColor
        folderRimMask.cornerCurve = .continuous
        folderRim.mask = folderRimMask
        setRimLight(direction: CGVector(dx: 0, dy: -1), strength: 0.5)
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TileLayer { itemID = other.itemID }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let noActions: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(),
        "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull(), "transform": NSNull(),
        "contents": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull(),
    ]

    static func size(for m: GridMetrics) -> CGSize {
        CGSize(width: m.itemWidth, height: m.iconSize + m.labelSpacing + LabelRenderer.height(fontSize: m.labelFontSize))
    }

    /// Re-renders only when something visible actually changed.
    func configure(content: Content, label: String, metrics m: GridMetrics, tint: CGColor? = nil, badge: Bool = false) {
        if let tint { setGlowColor(tint) }
        guard content != self.content || label != self.label || badge != self.badge || m != appliedMetrics else { return }
        let geometryChanged = m != appliedMetrics
        self.content = content
        self.label = label
        self.badge = badge
        appliedMetrics = m

        Motion.instantly {
            let size = Self.size(for: m)
            let s = m.iconSize
            if geometryChanged {
                bounds = CGRect(origin: .zero, size: size)
                let iconFrame = CGRect(x: (size.width - s) / 2, y: 0, width: s, height: s)
                iconHost.frame = iconFrame
                // Sibling layers share a 3D space: without this lift, half of the tilted
                // icon sinks behind the glow at z = 0 and gets cut along a visible seam.
                iconHost.zPosition = s * 0.6
                iconLayer.frame = iconHost.bounds
                let inner = s * 0.8  // macOS icons leave ~10% transparent margin
                let corner = inner * 0.225
                let innerRect = CGRect(x: s * 0.1, y: s * 0.1, width: inner, height: inner)
                iconLayer.shadowPath = CGPath(roundedRect: innerRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
                iconLayer.shadowRadius = s * 0.05
                iconLayer.shadowOffset = CGSize(width: 0, height: s * 0.025)
                highlightLayer.frame = CGRect(x: 0, y: -8, width: size.width, height: size.height + 14)
                highlightLayer.cornerRadius = s * 0.28

                glowLayer.frame = iconFrame.insetBy(dx: -s * 0.45, dy: -s * 0.45).offsetBy(dx: 0, dy: s * 0.08)
                specularHolder.frame = iconLayer.bounds
                specularMask.frame = specularHolder.bounds
                specular.bounds = CGRect(x: 0, y: 0, width: s * 1.5, height: s * 1.5)

                folderBackground.frame = innerRect
                folderBackground.cornerRadius = corner
                folderSheen.frame = folderBackground.bounds
                folderSheen.cornerRadius = corner
                folderDepth.frame = folderBackground.bounds
                folderDepth.cornerRadius = corner
                folderBevel.frame = folderBackground.bounds
                folderBevelMask.frame = folderBevel.bounds
                folderBevelMask.cornerRadius = corner
                folderBevelMask.borderWidth = s * 0.045
                folderRim.frame = folderBackground.bounds
                folderRimMask.frame = folderRim.bounds
                folderRimMask.cornerRadius = corner
                folderRimMask.borderWidth = max(0.75, s * 0.009)
                let dot = max(4, s * 0.05)
                runningDot.bounds = CGRect(x: 0, y: 0, width: dot, height: dot)
                runningDot.cornerRadius = dot / 2
                runningDot.shadowPath = CGPath(ellipseIn: runningDot.bounds, transform: nil)
                runningDot.position = CGPoint(x: size.width / 2, y: s + m.labelSpacing * 0.1)
            }

            let labelHeight = LabelRenderer.height(fontSize: m.labelFontSize)
            labelLayer.frame = CGRect(x: 0, y: s + m.labelSpacing, width: size.width, height: labelHeight)
            labelLayer.contents = LabelRenderer.image(label, fontSize: m.labelFontSize, width: size.width, badge: badge)

            switch content {
            case .app(let icon):
                folderBackground.removeFromSuperlayer()
                miniLayers.forEach { $0.removeFromSuperlayer() }
                miniLayers.removeAll()
                iconLayer.contents = icon
                specularMask.contents = icon
                specularMask.backgroundColor = nil
                specularMask.cornerRadius = 0
                specularMask.frame = specularHolder.bounds
            case .folder(let icons):
                iconLayer.contents = nil
                if folderBackground.superlayer == nil {
                    iconLayer.addSublayer(folderBackground)
                    folderBackground.addSublayer(folderDepth)
                    folderBackground.addSublayer(folderSheen)
                }
                layoutMiniIcons(icons, iconSize: s)
                if folderRim.superlayer == nil { folderBackground.addSublayer(folderRim) }
                specularMask.contents = nil
                specularMask.backgroundColor = NSColor.black.cgColor
                specularMask.frame = folderBackground.frame
                specularMask.cornerRadius = folderBackground.cornerRadius
                specularMask.cornerCurve = .continuous
            }
            // Keep the highlight above whatever the icon layer now holds.
            specularHolder.removeFromSuperlayer()
            iconLayer.addSublayer(specularHolder)
        }
    }

    private func layoutMiniIcons(_ icons: [CGImage?], iconSize s: CGFloat) {
        let shown = Array(icons.prefix(9))
        while miniLayers.count < shown.count {
            let l = PlainLayer()
            l.contentsGravity = .resizeAspect
            folderBackground.insertSublayer(l, above: folderSheen)
            miniLayers.append(l)
        }
        while miniLayers.count > shown.count { miniLayers.removeLast().removeFromSuperlayer() }

        // Always a 3×3 grid laid out by the visible artwork (each mini icon is a full
        // icon canvas with a ~10% transparent margin), so the art fills the pane
        // evenly with the same padding all round: the classic Launchpad proportions.
        let inner = s * 0.8
        let pad = inner * 0.11
        let gap = inner * 0.065
        let art = (inner - pad * 2 - gap * 2) / 3
        let canvas = art / 0.8
        for (i, l) in miniLayers.enumerated() {
            let col = CGFloat(i % 3), row = CGFloat(i / 3)
            let x = pad + col * (art + gap) - (canvas - art) / 2
            let y = pad + row * (art + gap) - (canvas - art) / 2
            l.frame = CGRect(x: x, y: y, width: canvas, height: canvas)
            l.contents = shown[i]
        }
    }

    /// Frame of mini icon `i` of a folder preview (a full icon canvas), in this
    /// tile's coordinates. Used to fly apps out of, and back into, the folder.
    func miniIconFrame(_ i: Int) -> CGRect? {
        guard i < miniLayers.count else { return nil }
        return convert(miniLayers[i].frame, from: folderBackground)
    }

    var miniIconCount: Int { miniLayers.count }

    /// Hides the preview's mini icons while their full-size copies are in flight.
    func setMiniIconsHidden(_ hidden: Bool) {
        Motion.instantly { miniLayers.forEach { $0.opacity = hidden ? 0 : 1 } }
    }

    // MARK: - Glass & light

    /// Folder glass body colour: the wallpaper behind it, brightened, so the pane
    /// looks like tinted frosted glass instead of grey plastic.
    func setGlassTint(_ color: CGColor) {
        let outlined = DisplayOptions.increaseContrast
        Motion.instantly {
            folderBackground.backgroundColor = color
            // Increase Contrast: a solid edge so the pane doesn't rely on its soft rim light.
            folderBackground.borderWidth = outlined ? 1 : 0
            folderBackground.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        }
    }

    func setRunning(_ running: Bool) {
        let target: Float = running ? 1 : 0
        guard runningDot.opacity != target else { return }
        Motion.fade(runningDot, to: target, duration: 0.25)
    }

    func setGlowColor(_ color: CGColor) {
        glowColor = color
        let clear = color.copy(alpha: 0) ?? NSColor.clear.cgColor
        Motion.instantly {
            glowLayer.colors = [color.copy(alpha: 0.62) ?? color, color.copy(alpha: 0.22) ?? color, clear]
            glowLayer.locations = [0, 0.42, 1]
        }
    }

    /// Points the bright side of the folder's rim toward the light (the pointer).
    /// `direction` is a unit vector from the folder toward the light, y down.
    func setRimLight(direction d: CGVector, strength: CGFloat) {
        let bright = NSColor.white.withAlphaComponent(0.4 + 0.35 * strength).cgColor
        let mid = NSColor.white.withAlphaComponent(0.12).cgColor
        let back = NSColor.white.withAlphaComponent(0.16 + 0.08 * strength).cgColor
        Motion.instantly {
            folderRim.colors = [bright, mid, back]
            folderRim.locations = [0, 0.55, 1]
            folderRim.startPoint = CGPoint(x: 0.5 + 0.5 * d.dx, y: 0.5 + 0.5 * d.dy)
            folderRim.endPoint = CGPoint(x: 0.5 - 0.5 * d.dx, y: 0.5 - 0.5 * d.dy)
        }
    }

    var isFolder: Bool { if case .folder = content { return true } else { return false } }

    /// Mirrors the system "Reduce motion" setting: hover keeps its light but no tilt.
    static var reduceMotion = false

    /// Pointer over the icon: tilt toward it, slide the specular highlight under it
    /// and bloom the colour glow. `nil` lets everything settle back.
    func setHover(_ local: CGPoint?) {
        if let local {
            let f = iconHost.frame
            let half = f.width / 2
            let dx = max(-1, min(1, (local.x - f.midX) / half))
            let dy = max(-1, min(1, (local.y - f.midY) / half))
            var t = CATransform3DIdentity
            if !Self.reduceMotion {
                t.m34 = -1 / 520
                t = CATransform3DScale(t, 1.07, 1.07, 1)
                t = CATransform3DRotate(t, dx * 0.17, 0, 1, 0)
                t = CATransform3DRotate(t, -dy * 0.17, 1, 0, 0)
            }
            animateHostTransform(to: t, spring: !hovering)

            let p = iconLayer.convert(local, from: self)
            Motion.instantly { specular.position = p }
            if !hovering {
                hovering = true
                Motion.fade(specularHolder, to: 1, duration: 0.2)
                Motion.fade(glowLayer, to: 1, duration: 0.28)
                Motion.instantly { glowLayer.transform = CATransform3DIdentity }
                glowLayer.add(Motion.spring("transform.scale", from: 0.75, to: 1, response: 0.5, damping: 0.8), forKey: "bloom")
            }
        } else if hovering {
            hovering = false
            animateHostTransform(to: CATransform3DIdentity, spring: true)
            Motion.fade(specularHolder, to: 0, duration: 0.25)
            Motion.fade(glowLayer, to: 0, duration: 0.35)
        }
    }

    private func animateHostTransform(to t: CATransform3D, spring: Bool) {
        let from = iconHost.presentation()?.transform ?? iconHost.transform
        iconHost.removeAnimation(forKey: "tilt")
        Motion.instantly { iconHost.transform = t }
        let a: CABasicAnimation = spring
            ? Motion.spring("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: t),
                            response: 0.42, damping: 0.62)
            : Motion.basic("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: t), duration: 0.08)
        iconHost.add(a, forKey: "tilt")
    }

    var isSelected: Bool = false {
        didSet {
            guard isSelected != oldValue else { return }
            Motion.fade(highlightLayer, to: isSelected ? 1 : 0, duration: 0.14)
        }
    }

    /// Frame of the visible icon artwork (without margins) in this layer's space.
    var iconArtworkFrame: CGRect {
        let f = iconHost.frame
        return f.insetBy(dx: f.width * 0.1, dy: f.height * 0.1)
    }

    /// Deepens the icon's shadow so a dragged icon looks lifted off the grid.
    func setLifted(_ lifted: Bool) {
        guard let m = appliedMetrics else { return }
        if lifted { setHover(nil) }
        let s = m.iconSize
        let targets: [(String, Any)] = [
            ("shadowRadius", lifted ? s * 0.14 : s * 0.05),
            ("shadowOpacity", lifted ? Float(0.32) : Self.restingShadow),
            ("shadowOffset", NSValue(size: CGSize(width: 0, height: lifted ? s * 0.09 : s * 0.025))),
        ]
        for (key, value) in targets {
            let from = iconLayer.presentation()?.value(forKey: key) ?? iconLayer.value(forKey: key)
            Motion.instantly { iconLayer.setValue(value, forKey: key) }
            iconLayer.add(Motion.basic(key, from: from, to: value, duration: 0.22), forKey: key)
        }
    }

    func startJiggle() {
        guard animation(forKey: "jiggle") == nil else { return }
        setHover(nil)
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = 0.022 + Double.random(in: 0...0.008)
        a.values = [-angle, angle, -angle]
        a.keyTimes = [0, 0.5, 1]
        a.duration = 0.26 + Double.random(in: 0...0.05)
        a.repeatCount = .infinity
        a.timeOffset = Double.random(in: 0...a.duration)
        a.isAdditive = true
        add(a, forKey: "jiggle")
    }

    func stopJiggle() {
        removeAnimation(forKey: "jiggle")
    }
}
