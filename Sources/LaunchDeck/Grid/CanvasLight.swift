import AppKit
import QuartzCore

/// Pointer-driven light: a diffuse glow that trails the cursor, hover tilt and
/// highlights on the icon under it, glass rims that catch the light, and the colour
/// bloom when an app launches.
extension LauncherCanvas {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: point(event))
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        clearHover()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        refreshLightMode()
    }

    func pointerMoved(to p: CGPoint) {
        guard isShown else { return }
        if !pointerInside {
            pointerInside = true
            refreshLightMode()
        }
        movePointerLight(to: p)
        feedComet(p)
        updateHover(at: p)
        updateRimLights(toward: p)
    }

    // MARK: - Comet

    func feedComet(_ p: CGPoint) {
        comet.add(p, at: CACurrentMediaTime())
        if cometLink == nil {
            let link = displayLink(target: self, selector: #selector(stepComet(_:)))
            link.add(to: .main, forMode: .common)
            cometLink = link
        }
        cometLink?.isPaused = false
    }

    @objc func stepComet(_ link: CADisplayLink) {
        if !comet.step(now: CACurrentMediaTime()) { link.isPaused = true }
    }

    /// Over empty space the pointer is a comet; resting on an icon it becomes the
    /// soft coloured light (plus the icon's own tilt and glow).
    func refreshLightMode() {
        let hovering = hoveredTile != nil
        let showComet = isShown && pointerInside && !hovering && drag == nil
        let showLight = isShown && hovering
        if comet.opacity != (showComet ? 1 : 0) { Motion.fade(comet, to: showComet ? 1 : 0, duration: showComet ? 0.22 : 0.14) }
        if pointerLight.opacity != (showLight ? 1 : 0) { Motion.fade(pointerLight, to: showLight ? 1 : 0, duration: 0.28) }
    }

    /// The glow tracks the pointer almost immediately: each event eases over a very
    /// short interval (about one frame of lag) instead of restarting a slow spring
    /// from rest, which left the light trailing behind.
    func movePointerLight(to p: CGPoint) {
        let first = lastPointer == nil
        lastPointer = p
        let from = pointerLight.presentation()?.position ?? pointerLight.position
        pointerLight.removeAnimation(forKey: "move")
        Motion.instantly { pointerLight.position = p }
        guard !first else { return }
        pointerLight.add(Motion.basic("position", from: NSValue(point: from), to: NSValue(point: p), duration: 0.08),
                         forKey: "move")
    }

    // MARK: - Hover

    func updateHover(at p: CGPoint) {
        var target: TileLayer?
        if drag == nil, !editing, !scrollDragging, press == nil {
            if let f = folder {
                target = folderIndex(at: p).flatMap { $0 < f.apps.count ? folderTiles["a:" + f.apps[$0]] : nil }
            } else if isSearching {
                target = resultIndex(at: p).flatMap { $0 < results.count ? resultTiles["r:" + results[$0].key] : nil }
            } else if let i = gridIndex(at: p), page < pages.count, i < pages[page].count {
                target = tiles[pages[page][i].id]
            }
        }
        if hoveredTile !== target {
            hoveredTile?.setHover(nil)
            hoveredTile = target
            tintPointerLight(target?.glowColor)
            refreshLightMode()
        }
        if let target { target.setHover(target.convert(p, from: root)) }
    }

    func clearHover() {
        hoveredTile?.setHover(nil)
        hoveredTile = nil
        tintPointerLight(nil)
        refreshLightMode()
    }

    /// The ambient light picks up the colour of the icon under the pointer, as if
    /// the icon were glowing onto the glass; white otherwise.
    func tintPointerLight(_ color: CGColor?) {
        let c = color ?? NSColor.white.cgColor
        let strong: CGFloat = color == nil ? 0.2 : 0.26
        let target = [c.copy(alpha: strong) ?? c, c.copy(alpha: 0.08) ?? c, c.copy(alpha: 0) ?? c]
        let from = pointerLight.presentation()?.colors ?? pointerLight.colors
        pointerLight.removeAnimation(forKey: "tint")
        Motion.instantly { pointerLight.colors = target }
        pointerLight.add(Motion.basic("colors", from: from, to: target, duration: 0.45), forKey: "tint")
    }

    // MARK: - Rim light

    /// Turns the bright edge of every visible glass pane toward the pointer; panes
    /// nearer the pointer catch more light.
    func updateRimLights(toward p: CGPoint) {
        let reach: CGFloat = 720
        func light(from center: CGPoint) -> (CGVector, CGFloat) {
            let dx = p.x - center.x, dy = p.y - center.y
            let distance = max(hypot(dx, dy), 1)
            let strength = max(0, 1 - distance / reach)
            // Far away, drift back toward the default light from above.
            let blend = strength
            var v = CGVector(dx: dx / distance * blend, dy: dy / distance * blend - (1 - blend))
            let len = max(hypot(v.dx, v.dy), 0.001)
            v = CGVector(dx: v.dx / len, dy: v.dy / len)
            return (v, strength)
        }

        if folder == nil, !isSearching, page < pages.count {
            let originX = strip.position.x + CGFloat(page) * width
            let iconOffset = metrics.iconSize / 2 - TileLayer.size(for: metrics).height / 2
            for (i, item) in pages[page].enumerated() where item.folder != nil {
                guard let t = tiles[item.id] else { continue }
                let c = metrics.center(for: i)
                let (direction, strength) = light(from: CGPoint(x: c.x + originX, y: c.y + iconOffset))
                t.setRimLight(direction: direction, strength: strength)
            }
        }
        if folder != nil, let rim = panel.sublayers?.first(where: { $0.name == "rim" }) as? CAGradientLayer {
            let f = panel.frame
            let (d, strength) = light(from: CGPoint(x: f.midX, y: f.midY))
            Motion.instantly {
                rim.colors = [NSColor.white.withAlphaComponent(0.4 + 0.4 * strength).cgColor,
                              NSColor.white.withAlphaComponent(0.1).cgColor,
                              NSColor.white.withAlphaComponent(0.2).cgColor]
                rim.startPoint = CGPoint(x: 0.5 + 0.5 * d.dx, y: 0.5 + 0.5 * d.dy)
                rim.endPoint = CGPoint(x: 0.5 - 0.5 * d.dx, y: 0.5 - 0.5 * d.dy)
            }
        }
    }

    // MARK: - Launch bloom

    /// A burst of the app's own colour spreading out from its icon as it opens.
    func bloom(at center: CGPoint, color: CGColor, below tile: CALayer) {
        let size = metrics.iconSize * 2.2
        let glow = CAGradientLayer()
        glow.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [color.copy(alpha: 0.7) ?? color, color.copy(alpha: 0.25) ?? color, color.copy(alpha: 0) ?? color]
        glow.locations = [0, 0.4, 1]
        glow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        glow.position = center
        glow.opacity = 0
        tile.superlayer?.insertSublayer(glow, below: tile)

        CATransaction.begin()
        CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
        let grow = Motion.basic("transform.scale", from: 0.5, to: 4.2, duration: 0.6)
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        glow.add(grow, forKey: "grow")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.18, 1]
        fade.duration = 0.6
        glow.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}
