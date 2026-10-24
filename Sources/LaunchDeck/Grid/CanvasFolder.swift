import AppKit
import QuartzCore

struct OpenFolder {
    var id: String
    var name: String
    var apps: [String]
    var columns: Int
    var rows: Int
    var visibleRows: Int
    var sourcePage: Int
    /// Folder contents use smaller icons and cells than the main grid.
    var metrics: GridMetrics
    /// Extra room above and below the rows so hover glows aren't clipped.
    var contentInset: CGFloat = 0
    var scroll: CGFloat = 0
}

extension LauncherCanvas: NSTextFieldDelegate {
    private static let titleHeight: CGFloat = 70
    private static let panelCorner: CGFloat = 36
    /// How far the inner-glow rings sit outside the glass (their shadow falls inside).
    private static let edgeOutset: CGFloat = 24
    /// Shared by the panel, its glass layers and the apps flying out, so everything
    /// grows as one piece.
    private static let openResponse: CGFloat = 0.5
    private static let openDamping: CGFloat = 0.9
    private static let snapshotContext = CIContext(options: [.cacheIntermediates: false])

    var folderTitleFrame: CGRect {
        guard folder != nil else { return .zero }
        let f = panel.frame
        return CGRect(x: f.minX + 40, y: f.minY + 16, width: f.width - 80, height: 40)
    }

    /// Same icon size as the grid so apps don't change size on the way in; cells are
    /// a touch tighter so the panel stays compact.
    private func folderMetrics() -> GridMetrics {
        var m = metrics
        m.cell = CGSize(width: (metrics.cell.width * 0.94).rounded(), height: (metrics.cell.height * 0.94).rounded())
        return m
    }

    /// Picks 4–6 columns so the last row is as full as possible (9 apps: 5 + 4,
    /// not 6 + 3), preferring the wider panel on a tie. Big folders use all 6.
    static func folderColumns(for count: Int) -> Int {
        guard count > 4 else { return max(count, 3) }
        guard count <= 18 else { return 6 }
        return (4...6).min { a, b in
            let gapA = (a - count % a) % a, gapB = (b - count % b) % b
            return gapA != gapB ? gapA < gapB : a > b
        } ?? 6
    }

    // MARK: - Open / close

    func openFolder(_ f: Folder) {
        guard folder == nil, let tile = tiles["f:" + f.id] else { return }
        clearHover()  // the folder icon may be tilted under the pointer
        // A previous folder may still be animating closed: drop its tiles and
        // animations now so nothing from it lingers in this one.
        for l in [panel, panelContent, panelTitle, blurLayer, scrim] { l.removeAllAnimations() }
        Motion.instantly { folderStrip.sublayers?.forEach { $0.removeFromSuperlayer() } }
        folderTiles.removeAll()
        let fm = folderMetrics()
        let n = f.apps.count
        let columns = Self.folderColumns(for: n)
        let rows = max(1, (n + columns - 1) / columns)
        let available = metrics.size.height - metrics.searchBarY * 2 - Self.titleHeight
        let visibleRows = min(rows, 4, max(1, Int(available / fm.cell.height)))
        let inset = min((fm.iconSize * 0.5).rounded(), Self.titleHeight - 30)
        folder = OpenFolder(id: f.id, name: f.name, apps: f.apps, columns: columns, rows: rows,
                            visibleRows: visibleRows, sourcePage: page, metrics: fm, contentInset: inset)
        selection = nil
        refreshSelection()
        chrome.hidesChrome = true
        chrome.isFocused = false
        chrome.isHovered = false

        let pad = (fm.cell.width * 0.32).rounded()
        let contentSize = CGSize(width: CGFloat(columns) * fm.cell.width, height: CGFloat(visibleRows) * fm.cell.height)
        // A scrolling folder's content reaches `inset` below its last visible row (the
        // next row fades in there), so the panel has to be that much taller to hold it.
        let bottom = rows > visibleRows ? inset : pad * 0.45
        let panelSize = CGSize(width: contentSize.width + pad * 2, height: Self.titleHeight + contentSize.height + bottom)
        let panelFrame = CGRect(x: ((width - panelSize.width) / 2).rounded(),
                                y: max(metrics.searchBarY, (metrics.size.height - panelSize.height) / 2 - 12).rounded(),
                                width: panelSize.width, height: panelSize.height)
        let from = folderLayer.convert(tile.iconArtworkFrame, from: tile)
        let backdropImage = blurredGridSnapshot()
        // The frost covers the panel's own body colour, so the solid Reduce
        // Transparency body only shows without it.
        let frostImage = DisplayOptions.reduceTransparency ? nil : frostSnapshot()

        Motion.instantly {
            folderLayer.isHidden = false
            folderLayer.opacity = 1
            styleGlassPanel()
            panel.frame = panelFrame
            panel.cornerRadius = Self.panelCorner
            panel.opacity = 1
            // The content area reaches `inset` beyond the rows so glows can spill over;
            // only scrolling folders clip, and then with a soft fade.
            panelContent.frame = CGRect(x: pad, y: Self.titleHeight - inset, width: contentSize.width,
                                        height: contentSize.height + inset * 2)
            panelContent.opacity = 1
            folderStrip.frame = CGRect(x: 0, y: inset, width: contentSize.width, height: CGFloat(rows) * fm.cell.height)
            renderFolderTitle(f.name)
            // The scroll fade would hide apps flying in from outside the content
            // area, so it goes on once they've landed.
            applyScrollFade(false, inset: inset)
            blurLayer.contents = backdropImage
            blurLayer.opacity = backdropImage == nil ? 0 : 0.75
            panelFrostImage?.contents = frostImage
            for (l, _) in glassDecor { l.opacity = 1 }
        }
        // Grow out of the folder icon, glass edges and highlights riding along.
        springGlass(from: from, to: panelFrame, fromCorner: from.width * 0.225, toCorner: Self.panelCorner,
                    response: Self.openResponse, damping: Self.openDamping)
        panel.add(Motion.basic("opacity", from: 0.4, to: 1, duration: 0.22), forKey: "fade")
        if let p = lastPointer { updateRimLights(toward: p) }

        let titleFade = Motion.basic("opacity", from: 0, to: 1, duration: 0.22)
        titleFade.beginTime = CACurrentMediaTime() + 0.12
        titleFade.fillMode = .backwards
        panelTitle.add(titleFade, forKey: "fade")

        // Apps fly out of the folder icon's preview: each starts on its mini icon and
        // rides the same spring as the panel, so it stays glued to the glass.
        var origins: [CGRect] = []
        if !reduceMotion {
            let stripOrigin = CGPoint(x: from.minX + panelContent.frame.minX + folderStrip.frame.minX,
                                      y: from.minY + panelContent.frame.minY + folderStrip.frame.minY)
            for i in 0..<tile.miniIconCount {
                guard let mini = tile.miniIconFrame(i) else { continue }
                origins.append(folderLayer.convert(mini, from: tile).offsetBy(dx: -stripOrigin.x, dy: -stripOrigin.y))
            }
        }
        tile.setMiniIconsHidden(true)
        layoutFolderTiles(f.apps, animated: false, appear: true, origins: origins)
        if rows > visibleRows {
            // Rows below the fold stay hidden while the panel grows, then the scroll
            // fade goes on and the next row eases in under it.
            let id = f.id, firstHidden = visibleRows * columns
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, let open = self.folder, open.id == id else { return }
                self.applyScrollFade(true, inset: inset)
                for (i, key) in open.apps.enumerated() where i >= firstHidden {
                    if let t = self.folderTiles["a:" + key] { Motion.fade(t, to: 1, duration: 0.3) }
                }
            }
        }

        // The sharp grid fades away to reveal its blurred copy underneath, so the
        // brightness never dips; both recede slightly for depth.
        Motion.fade(tile, to: 0, duration: 0.1)
        Motion.fade(gridContainer, to: 0, duration: 0.26)
        Motion.scale(gridContainer, to: 0.95, response: 0.5, damping: 0.92)
        Motion.scale(blurLayer, to: 0.95, response: 0.5, damping: 0.92)
        Motion.fade(scrim, to: 1, duration: 0.3)
    }

    func closeFolder(animated: Bool) {
        guard let f = folder else { return }
        if titleField != nil { finishRenaming() }
        folder = nil
        selection = nil
        chrome.hidesChrome = false

        let folderTile = tiles["f:" + f.id]
        let closing = folderTiles
        let tilesToRemove = Array(folderTiles.values)
        folderTiles.removeAll()
        clearHover()

        let cleanup = { [weak self] in
            guard let self else { return }
            Motion.instantly {
                // These tiles belong to the closed folder whatever happened since.
                tilesToRemove.forEach { $0.removeFromSuperlayer() }
                guard self.folder == nil else { return }
                self.folderLayer.isHidden = true
                self.blurLayer.contents = nil
                self.panelFrostImage?.contents = nil
            }
        }

        guard animated else {
            for l in [panel, panelContent, panelTitle, gridContainer, blurLayer, scrim] { l.removeAllAnimations() }
            Motion.instantly {
                gridContainer.opacity = isSearching ? 0 : 1
                gridContainer.transform = CATransform3DIdentity
                blurLayer.opacity = 0
                blurLayer.transform = CATransform3DIdentity
                scrim.opacity = 0
                folderTile?.opacity = 1
            }
            folderTile?.setMiniIconsHidden(false)
            cleanup()
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock(cleanup)

        // Bring the sharp grid back over the blurred copy, then let the copy go:
        // a focus pull rather than a dark-to-bright flash.
        Motion.fade(gridContainer, to: isSearching ? 0 : 1, duration: 0.3)
        Motion.scale(gridContainer, to: 1, response: 0.46, damping: 0.92)
        Motion.scale(blurLayer, to: 1, response: 0.46, damping: 0.92)
        let blurOut = Motion.basic("opacity", from: blurLayer.presentation()?.opacity ?? 0.75, to: 0, duration: 0.42,
                                   timing: .easeIn)
        blurLayer.removeAnimation(forKey: "fade")
        Motion.instantly { blurLayer.opacity = 0 }
        blurLayer.add(blurOut, forKey: "fade")
        Motion.fade(scrim, to: 0, duration: 0.34)

        Motion.fade(panelTitle, to: 0, duration: 0.1)
        if let folderTile, page == f.sourcePage {
            // Shrink back into the folder icon, the apps flying home into its preview.
            let to = folderLayer.convert(folderTile.iconArtworkFrame, from: folderTile)
            folderTile.setMiniIconsHidden(false)
            if reduceMotion || f.scroll > 1 {
                Motion.fade(panelContent, to: 0, duration: 0.1)
            } else {
                panelContent.mask = nil  // let the apps fly out past the scroll fade
                let stripOrigin = CGPoint(x: to.minX + panelContent.frame.minX + folderStrip.frame.minX,
                                          y: to.minY + panelContent.frame.minY + folderStrip.frame.minY)
                for (i, key) in f.apps.enumerated() {
                    guard let t = closing["a:" + key] else { continue }
                    guard i < folderTile.miniIconCount, let mini = folderTile.miniIconFrame(i) else {
                        Motion.fade(t, to: 0, duration: 0.1)
                        continue
                    }
                    let end = folderLayer.convert(mini, from: folderTile).offsetBy(dx: -stripOrigin.x, dy: -stripOrigin.y)
                    fly(t, to: end, metrics: f.metrics)
                }
            }
            let current = panel.presentation()?.frame ?? panel.frame
            let corner = (panel.presentation()?.cornerRadius) ?? Self.panelCorner
            springGlass(from: current, to: to, fromCorner: corner, toCorner: to.width * 0.225, response: 0.38, damping: 0.95)
            Motion.instantly { panel.opacity = 0 }
            let fade = Motion.basic("opacity", from: 1, to: 0, duration: 0.12)
            fade.beginTime = CACurrentMediaTime() + 0.2
            fade.fillMode = .backwards
            panel.add(fade, forKey: "fade")
            let reveal = Motion.basic("opacity", from: 0, to: 1, duration: 0.14)
            reveal.beginTime = CACurrentMediaTime() + 0.18
            reveal.fillMode = .backwards
            Motion.instantly { folderTile.opacity = 1 }
            folderTile.add(reveal, forKey: "fade")
        } else {
            Motion.fade(panelContent, to: 0, duration: 0.1)
            Motion.fade(panel, to: 0, duration: 0.18)
            folderTile?.setMiniIconsHidden(false)
            folderTile.map { Motion.fade($0, to: 1, duration: 0.2) }
        }
        CATransaction.commit()
    }

    /// Where a folder tile must sit (and how small) so its icon covers `rect`.
    private func placement(for rect: CGRect, metrics m: GridMetrics) -> (CGPoint, CGFloat) {
        let k = rect.width / m.iconSize
        let iconOffset = m.iconSize / 2 - TileLayer.size(for: m).height / 2
        return (CGPoint(x: rect.midX, y: rect.midY - iconOffset * k), k)
    }

    /// Closing: shrinks an app tile into its mini icon slot, then lets it vanish
    /// as the folder icon fades back in under it.
    private func fly(_ t: TileLayer, to rect: CGRect, metrics m: GridMetrics) {
        let (pos, k) = placement(for: rect, metrics: m)
        Motion.move(t, to: pos, response: 0.38, damping: 0.95)
        Motion.scale(t, to: k, response: 0.38, damping: 0.95)
        Motion.fade(t.labelLayer, to: 0, duration: 0.1)
        let fade = Motion.basic("opacity", from: 1, to: 0, duration: 0.1)
        fade.beginTime = CACurrentMediaTime() + 0.22
        fade.fillMode = .backwards
        Motion.instantly { t.opacity = 0 }
        t.add(fade, forKey: "fade")
    }

    /// When a folder scrolls, its contents fade out at the top and bottom edges
    /// instead of being cut off.
    private func applyScrollFade(_ enabled: Bool, inset: CGFloat) {
        panelContent.masksToBounds = false
        let height = panelContent.bounds.height
        guard enabled, height > 0 else {
            panelContent.mask = nil
            return
        }
        // Fully visible across the rows; fading out through the insets.
        let mask = CAGradientLayer()
        mask.frame = panelContent.bounds
        let edge = Double(inset / height)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        panelContent.mask = mask
    }

    /// Renders the grid as it looks right now and blurs it, for the folder backdrop.
    private func blurredGridSnapshot() -> CGImage? {
        guard let image = renderRoot(scale: 0.5, withWallpaper: false) else { return nil }
        let source = CIImage(cgImage: image)
        // Keep the blurred icons vivid so the backdrop reads as colour, not grey haze.
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 15)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6, kCIInputBrightnessKey: 0.03])
            .cropped(to: source.extent)
        return Self.snapshotContext.createCGImage(blurred, from: source.extent)
    }

    /// The panel's own frost: wallpaper and grid diffused far more than the backdrop,
    /// so through the glass the icons melt into soft washes of colour instead of
    /// reading as smudges. Kept a touch darker than the scene so white names hold up.
    private func frostSnapshot() -> CGImage? {
        // Over the live desktop there is no picture to draw (the window server blurs
        // it), so the frost is the icons alone and the live blur shows through it.
        guard let image = renderRoot(scale: 0.25, withWallpaper: hasWallpaper) else { return nil }
        let source = CIImage(cgImage: image)
        let frosted = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.03])
            .cropped(to: source.extent)
        return Self.snapshotContext.createCGImage(frosted, from: source.extent)
    }

    private func renderRoot(scale: CGFloat, withWallpaper: Bool) -> CGImage? {
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // The layer tree is y-down; flip to match the bitmap.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        Motion.instantly {
            backdrop.isHidden = !withWallpaper
            blurLayer.isHidden = true
        }
        root.render(in: ctx)
        Motion.instantly {
            backdrop.isHidden = false
            blurLayer.isHidden = false
        }
        return ctx.makeImage()
    }

    private var panelSheen: CAGradientLayer? {
        panel.sublayers?.first { $0.name == "sheen" } as? CAGradientLayer
    }

    /// Screen-sized frost image inside the panel's "frost" clip, kept aligned with
    /// the screen while the panel moves (see springGlass).
    private var panelFrostImage: CALayer? {
        panel.sublayers?.first { $0.name == "frost" }?.sublayers?.first
    }

    private var panelRim: CAGradientLayer? {
        panel.sublayers?.first { $0.name == "rim" } as? CAGradientLayer
    }

    /// The panel's glass layers (and their masks and edge rings) with how far each
    /// sits inside its parent; negative means outside.
    private var glassDecor: [(CALayer, CGFloat)] {
        var out: [(CALayer, CGFloat)] = []
        for l in panel.sublayers ?? [] where ["frost", "sheen", "rim", "innerLight", "innerShade"].contains(l.name ?? "") {
            out.append((l, 0))
            if let m = l.mask { out.append((m, 0)) }
            for c in l.sublayers ?? [] where c.name == "edge" { out.append((c, -Self.edgeOutset)) }
        }
        return out
    }

    /// Springs the panel and every glass layer in it between two frames together,
    /// so highlights and edges stay attached to the glass as it grows or shrinks.
    private func springGlass(from: CGRect, to: CGRect, fromCorner: CGFloat, toCorner: CGFloat,
                             response: CGFloat, damping: CGFloat) {
        func spring(_ l: CALayer, _ key: String, _ a: Any, _ b: Any) {
            l.add(Motion.spring(key, from: a, to: b, response: response, damping: damping), forKey: key)
        }
        Motion.instantly {
            panel.bounds = CGRect(origin: .zero, size: to.size)
            panel.position = CGPoint(x: to.midX, y: to.midY)
            panel.cornerRadius = toCorner
        }
        spring(panel, "bounds", NSValue(rect: CGRect(origin: .zero, size: from.size)), NSValue(rect: panel.bounds))
        spring(panel, "position", NSValue(point: CGPoint(x: from.midX, y: from.midY)), NSValue(point: panel.position))
        spring(panel, "cornerRadius", fromCorner, toCorner)
        for (l, inset) in glassDecor {
            let a = CGRect(origin: .zero, size: from.size).insetBy(dx: inset, dy: inset)
            let b = CGRect(origin: .zero, size: to.size).insetBy(dx: inset, dy: inset)
            Motion.instantly {
                l.frame = b
                l.cornerRadius = max(0, toCorner - inset)
            }
            spring(l, "bounds", NSValue(rect: CGRect(origin: .zero, size: a.size)), NSValue(rect: CGRect(origin: .zero, size: b.size)))
            spring(l, "position", NSValue(point: CGPoint(x: a.midX, y: a.midY)), NSValue(point: CGPoint(x: b.midX, y: b.midY)))
            spring(l, "cornerRadius", max(0, fromCorner - inset), max(0, toCorner - inset))
        }
        // The frost image rides inside the panel, so it has to slide the opposite way
        // to stay put on screen. The panel's origin follows the same spring curve as
        // its position and size, so one matching spring cancels it exactly.
        if let frost = panelFrostImage {
            let screen = folderLayer.bounds
            let a = CGPoint(x: screen.midX - from.minX, y: screen.midY - from.minY)
            let b = CGPoint(x: screen.midX - to.minX, y: screen.midY - to.minY)
            Motion.instantly {
                frost.bounds = CGRect(origin: .zero, size: screen.size)
                frost.position = b
            }
            spring(frost, "position", NSValue(point: a), NSValue(point: b))
        }
    }

    /// Clear glass: an almost transparent body, a crisp hairline edge and a soft
    /// highlight falling from the top, so the wallpaper shows through rather than
    /// being washed grey.
    /// Glass with some weight: a denser frosted body, a highlight across the top,
    /// light caught inside the upper edge and a little shade inside the lower one
    /// (the glass's thickness), a hairline rim turned toward the pointer and a deep,
    /// soft shadow underneath.
    private func styleGlassPanel() {
        panel.masksToBounds = false
        panel.cornerCurve = .continuous
        panel.backgroundColor = panelBodyColor()
        let outlined = DisplayOptions.increaseContrast
        // A dark hairline just outside the rim light: the edge of the glass reads
        // against bright wallpaper as well as dark (the macOS 27 glass edge).
        panel.borderColor = outlined ? NSColor.white.withAlphaComponent(0.7).cgColor
                                     : NSColor.black.withAlphaComponent(0.1).cgColor
        panel.borderWidth = outlined ? 1.5 : 0.5
        panel.shadowColor = NSColor.black.cgColor
        panel.shadowOpacity = 0.26
        panel.shadowRadius = 50
        panel.shadowOffset = CGSize(width: 0, height: 26)

        guard panelSheen == nil else { return }
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "frame": NSNull(),
                                         "cornerRadius": NSNull(), "colors": NSNull(), "startPoint": NSNull(),
                                         "endPoint": NSNull()]

        let sheen = CAGradientLayer()
        sheen.name = "sheen"
        sheen.colors = [NSColor.white.withAlphaComponent(0.09).cgColor,
                        NSColor.white.withAlphaComponent(0.02).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        sheen.locations = [0, 0.22, 1]
        sheen.cornerCurve = .continuous
        sheen.masksToBounds = true
        sheen.actions = still
        panel.insertSublayer(sheen, at: 0)

        let frost = PlainLayer()
        frost.name = "frost"
        frost.masksToBounds = true
        frost.cornerCurve = .continuous
        let frostImage = PlainLayer()
        frostImage.contentsGravity = .resize
        frost.addSublayer(frostImage)
        panel.insertSublayer(frost, below: sheen)

        // Inner edges: a ring just outside the glass casts its shadow inward, clipped
        // to the glass, so light pools softly along the inside of the rim.
        func innerEdge(_ name: String, color: NSColor, opacity: Float, offset: CGFloat) -> CALayer {
            let clip = PlainLayer()
            clip.name = name
            clip.masksToBounds = true
            clip.cornerCurve = .continuous
            let edge = PlainLayer()
            edge.name = "edge"
            edge.borderWidth = Self.edgeOutset
            edge.borderColor = NSColor.black.cgColor
            edge.cornerCurve = .continuous
            edge.shadowColor = color.cgColor
            edge.shadowOpacity = opacity
            edge.shadowRadius = 12
            edge.shadowOffset = CGSize(width: 0, height: offset)
            clip.addSublayer(edge)
            return clip
        }
        panel.insertSublayer(innerEdge("innerLight", color: .white, opacity: 0.28, offset: 7), above: sheen)
        panel.insertSublayer(innerEdge("innerShade", color: .black, opacity: 0.22, offset: -7), above: sheen)

        // Rim light: a gradient seen only through a hairline ring, its bright side
        // turned toward the pointer (see updateRimLights).
        let rim = CAGradientLayer()
        rim.name = "rim"
        rim.actions = still
        rim.colors = Self.panelRimColors(strength: 0.5)
        rim.locations = [0, 0.3, 0.7, 1]
        let ring = PlainLayer()
        ring.borderColor = NSColor.black.cgColor
        ring.borderWidth = 1
        ring.cornerCurve = .continuous
        rim.mask = ring
        panel.addSublayer(rim)
    }

    /// Near-clear frost normally. Under Reduce Transparency the pane turns into a
    /// dark slab of the wallpaper's own colour, so white names stay readable and
    /// the blurred grid no longer shows through.
    private func panelBodyColor() -> CGColor {
        guard DisplayOptions.reduceTransparency else { return NSColor.white.withAlphaComponent(0.13).cgColor }
        let center = CGPoint(x: metrics.size.width / 2, y: metrics.size.height / 2)
        let base = sampler?.color(at: center, in: metrics.size) ?? NSColor(white: 0.3, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        return NSColor(hue: h, saturation: min(s, 0.35), brightness: min(v, 0.32), alpha: 0.94).cgColor
    }

    /// Specular along the side facing the light, a fainter echo on the opposite
    /// side (light passing through the glass) and dim flanks in between.
    static func panelRimColors(strength: CGFloat) -> [CGColor] {
        [NSColor.white.withAlphaComponent(0.34 + 0.36 * strength).cgColor,
         NSColor.white.withAlphaComponent(0.08).cgColor,
         NSColor.white.withAlphaComponent(0.05).cgColor,
         NSColor.white.withAlphaComponent(0.16 + 0.06 * strength).cgColor]
    }

    private func renderFolderTitle(_ name: String) {
        let w = panel.bounds.width - 80
        panelTitle.contentsGravity = .resize
        panelTitle.frame = CGRect(x: 40, y: 20, width: w, height: LabelRenderer.height(fontSize: 24))
        panelTitle.contents = LabelRenderer.image(name, fontSize: 24, width: w, weight: .semibold)
        panelTitle.opacity = 1
    }

    // MARK: - Folder contents

    func folderCenter(_ i: Int, columns: Int) -> CGPoint {
        let cell = folder?.metrics.cell ?? metrics.cell
        return CGPoint(x: cell.width * (CGFloat(i % columns) + 0.5), y: cell.height * (CGFloat(i / columns) + 0.5))
    }

    /// Places folder tiles in `order`; the placeholder key leaves a gap during drags.
    /// `origins` (opening only) are the mini icon frames, in strip coordinates, that
    /// the first apps fly out from.
    func layoutFolderTiles(_ order: [String], animated: Bool, appear: Bool = false, origins: [CGRect] = []) {
        guard let f = folder else { return }
        let draggedID = drag?.item.id
        var live = Set<String>()
        let now = CACurrentMediaTime()
        for (i, key) in order.enumerated() where key != placeholderKey {
            let id = "a:" + key
            guard id != draggedID else { continue }
            live.insert(id)
            let target = folderCenter(i, columns: f.columns)
            if let t = folderTiles[id] {
                configure(t, .app(key), metrics: f.metrics)
                if animated { Motion.move(t, to: target) } else { Motion.instantly { t.position = target } }
            } else {
                let t = TileLayer(itemID: id)
                configure(t, .app(key), metrics: f.metrics)
                Motion.instantly { t.position = target }
                folderStrip.addSublayer(t)
                folderTiles[id] = t
                if appear, f.rows > f.visibleRows, i >= f.visibleRows * f.columns {
                    Motion.instantly { t.opacity = 0 }  // revealed once the scroll fade is on
                } else if appear, i < origins.count {
                    let (start, k) = placement(for: origins[i], metrics: f.metrics)
                    t.add(Motion.spring("position", from: NSValue(point: start), to: NSValue(point: target),
                                        response: Self.openResponse, damping: Self.openDamping), forKey: "move")
                    t.add(Motion.spring("transform.scale", from: k, to: 1, response: Self.openResponse,
                                        damping: Self.openDamping), forKey: "scale")
                    let label = Motion.basic("opacity", from: 0, to: 1, duration: 0.2)
                    label.beginTime = now + 0.16
                    label.fillMode = .backwards
                    t.labelLayer.add(label, forKey: "fade")
                } else if appear {
                    let begin = now + 0.08 + Double(i) * 0.012
                    let fade = Motion.basic("opacity", from: 0, to: 1, duration: 0.2)
                    fade.beginTime = begin
                    fade.fillMode = .backwards
                    t.add(fade, forKey: "fade")
                    let pop = Motion.spring("transform.scale", from: 0.7, to: 1, response: 0.4, damping: 0.75)
                    pop.beginTime = begin
                    pop.fillMode = .backwards
                    t.add(pop, forKey: "appear")
                }
            }
            if editing { folderTiles[id]?.startJiggle() }
        }
        for (id, t) in folderTiles where !live.contains(id) {
            t.removeFromSuperlayer()
            folderTiles[id] = nil
        }
    }

    func refreshFolderTiles(_ f: Folder) {
        folder?.apps = f.apps
        folder?.name = f.name
        layoutFolderTiles(f.apps, animated: true)
    }

    func folderIndex(at p: CGPoint) -> Int? {
        guard let f = folder else { return nil }
        let inContent = panelContent.convert(p, from: root)
        guard panelContent.bounds.contains(inContent) else { return nil }
        let local = folderStrip.convert(p, from: root)
        let m = f.metrics
        let size = TileLayer.size(for: m)
        for i in f.apps.indices {
            let c = folderCenter(i, columns: f.columns)
            let hit = CGRect(x: c.x - m.iconSize * 0.62, y: c.y - size.height / 2,
                             width: m.iconSize * 1.24, height: size.height)
            if hit.contains(local) { return i }
        }
        return nil
    }

    func scrollFolder(_ event: NSEvent) {
        guard var f = folder, f.rows > f.visibleRows else { return }
        let maxScroll = CGFloat(f.rows - f.visibleRows) * f.metrics.cell.height
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        f.scroll = min(max(f.scroll - delta, 0), maxScroll)
        folder = f
        Motion.instantly { folderStrip.frame.origin.y = f.contentInset - f.scroll }
    }

    // MARK: - Renaming

    func beginRenaming() {
        guard let f = folder, titleField == nil, let host = superview else { return }
        let field = NSTextField(string: f.name)
        field.frame = host.convert(folderTitleFrame, from: self)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 24, weight: .semibold)
        field.textColor = .white
        field.delegate = self
        host.addSubview(field)
        titleField = field
        Motion.instantly { panelTitle.opacity = 0 }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func finishRenaming() {
        guard let field = titleField else { return }
        titleField = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if let f = folder {
            let finalName = name.isEmpty ? f.name : name
            if finalName != f.name {
                store.updateFolder(id: f.id) { $0.name = finalName }
                folder?.name = finalName
                if let updated = store.folder(id: f.id), let t = tiles["f:" + f.id] { configure(t, .folder(updated)) }
            }
            Motion.instantly { renderFolderTitle(finalName) }
        }
        window?.makeFirstResponder(self)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finishRenaming()
    }
}
