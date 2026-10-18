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

    // MARK: - Open / close

    func openFolder(_ f: Folder) {
        guard folder == nil, let tile = tiles["f:" + f.id] else { return }
        // A previous folder may still be animating closed: drop its tiles and
        // animations now so nothing from it lingers in this one.
        for l in [panel, panelContent, panelTitle, blurLayer, scrim] { l.removeAllAnimations() }
        Motion.instantly { folderStrip.sublayers?.forEach { $0.removeFromSuperlayer() } }
        folderTiles.removeAll()
        let fm = folderMetrics()
        let n = f.apps.count
        let columns = min(6, max(4, n))
        let rows = max(1, (n + columns - 1) / columns)
        let available = metrics.size.height - metrics.searchBarY * 2 - Self.titleHeight
        let visibleRows = min(rows, 4, max(1, Int(available / fm.cell.height)))
        let inset = min((fm.iconSize * 0.5).rounded(), Self.titleHeight - 30)
        folder = OpenFolder(id: f.id, name: f.name, apps: f.apps, columns: columns, rows: rows,
                            visibleRows: visibleRows, sourcePage: page, metrics: fm, contentInset: inset)
        selection = nil
        refreshSelection()
        chrome.hidesChrome = true

        let pad = (fm.cell.width * 0.32).rounded()
        let contentSize = CGSize(width: CGFloat(columns) * fm.cell.width, height: CGFloat(visibleRows) * fm.cell.height)
        let panelSize = CGSize(width: contentSize.width + pad * 2, height: Self.titleHeight + contentSize.height + pad * 0.45)
        let panelFrame = CGRect(x: ((width - panelSize.width) / 2).rounded(),
                                y: max(metrics.searchBarY, (metrics.size.height - panelSize.height) / 2 - 12).rounded(),
                                width: panelSize.width, height: panelSize.height)
        let from = folderLayer.convert(tile.iconArtworkFrame, from: tile)
        let backdropImage = blurredGridSnapshot()

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
            applyScrollFade(rows > visibleRows, inset: inset)
            blurLayer.contents = backdropImage
            blurLayer.opacity = backdropImage == nil ? 0 : 0.75
            for l in [panelSheen, panelRim] as [CALayer?] {
                guard let l else { continue }
                l.frame = CGRect(origin: .zero, size: panelFrame.size)
                l.mask?.frame = l.bounds
                l.opacity = 1
            }
        }
        // Grow out of the folder icon.
        panel.add(Motion.spring("bounds", from: NSValue(rect: CGRect(origin: .zero, size: from.size)),
                                to: NSValue(rect: CGRect(origin: .zero, size: panelFrame.size)), response: 0.46, damping: 0.86),
                  forKey: "bounds")
        panel.add(Motion.spring("position", from: NSValue(point: CGPoint(x: from.midX, y: from.midY)),
                                to: NSValue(point: CGPoint(x: panelFrame.midX, y: panelFrame.midY)), response: 0.46, damping: 0.86),
                  forKey: "position")
        panel.add(Motion.basic("cornerRadius", from: from.width * 0.225, to: Self.panelCorner, duration: 0.3), forKey: "corner")
        panel.add(Motion.basic("opacity", from: 0.3, to: 1, duration: 0.16), forKey: "fade")

        // The glass sheen only appears once the panel is near full size.
        for l in [panelSheen, panelRim] as [CALayer?] {
            guard let l else { continue }
            let fadeIn = Motion.basic("opacity", from: 0, to: 1, duration: 0.24)
            fadeIn.beginTime = CACurrentMediaTime() + 0.16
            fadeIn.fillMode = .backwards
            l.add(fadeIn, forKey: "fade")
        }
        if let p = lastPointer { updateRimLights(toward: p) }

        let titleFade = Motion.basic("opacity", from: 0, to: 1, duration: 0.22)
        titleFade.beginTime = CACurrentMediaTime() + 0.12
        titleFade.fillMode = .backwards
        panelTitle.add(titleFade, forKey: "fade")

        layoutFolderTiles(f.apps, animated: false, appear: true)

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
        let tilesToRemove = Array(folderTiles.values)
        folderTiles.removeAll()

        let cleanup = { [weak self] in
            guard let self else { return }
            Motion.instantly {
                // These tiles belong to the closed folder whatever happened since.
                tilesToRemove.forEach { $0.removeFromSuperlayer() }
                guard self.folder == nil else { return }
                self.folderLayer.isHidden = true
                self.blurLayer.contents = nil
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

        Motion.fade(panelContent, to: 0, duration: 0.1)
        Motion.fade(panelTitle, to: 0, duration: 0.1)
        for l in [panelSheen, panelRim] as [CALayer?] { if let l { Motion.fade(l, to: 0, duration: 0.08) } }
        if let folderTile, page == f.sourcePage {
            // Shrink back into the folder icon.
            let to = folderLayer.convert(folderTile.iconArtworkFrame, from: folderTile)
            let current = panel.presentation()?.frame ?? panel.frame
            Motion.instantly {
                panel.bounds = CGRect(origin: .zero, size: to.size)
                panel.position = CGPoint(x: to.midX, y: to.midY)
                panel.cornerRadius = to.width * 0.225
                panel.opacity = 0
            }
            panel.add(Motion.spring("bounds", from: NSValue(rect: CGRect(origin: .zero, size: current.size)),
                                    to: NSValue(rect: panel.bounds), response: 0.36, damping: 0.95), forKey: "bounds")
            panel.add(Motion.spring("position", from: NSValue(point: CGPoint(x: current.midX, y: current.midY)),
                                    to: NSValue(point: panel.position), response: 0.36, damping: 0.95), forKey: "position")
            panel.add(Motion.basic("cornerRadius", from: Self.panelCorner, to: panel.cornerRadius, duration: 0.25), forKey: "corner")
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
            Motion.fade(panel, to: 0, duration: 0.18)
            folderTile.map { Motion.fade($0, to: 1, duration: 0.2) }
        }
        CATransaction.commit()
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
        let scale: CGFloat = 0.5
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
            backdrop.isHidden = true
            blurLayer.isHidden = true
        }
        root.render(in: ctx)
        Motion.instantly {
            backdrop.isHidden = false
            blurLayer.isHidden = false
        }
        guard let image = ctx.makeImage() else { return nil }
        let source = CIImage(cgImage: image)
        // Keep the blurred icons vivid so the backdrop reads as colour, not grey haze.
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: 15)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6, kCIInputBrightnessKey: 0.03])
            .cropped(to: source.extent)
        return Self.snapshotContext.createCGImage(blurred, from: source.extent)
    }

    private var panelSheen: CAGradientLayer? {
        panel.sublayers?.first { $0.name == "sheen" } as? CAGradientLayer
    }

    private var panelRim: CAGradientLayer? {
        panel.sublayers?.first { $0.name == "rim" } as? CAGradientLayer
    }

    /// Clear glass: an almost transparent body, a crisp hairline edge and a soft
    /// highlight falling from the top, so the wallpaper shows through rather than
    /// being washed grey.
    private func styleGlassPanel() {
        panel.masksToBounds = false
        panel.cornerCurve = .continuous
        panel.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        // A faint base edge; the gradient rim on top carries the light.
        panel.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        panel.borderWidth = 0.5
        panel.shadowColor = NSColor.black.cgColor
        panel.shadowOpacity = 0.14
        panel.shadowRadius = 44
        panel.shadowOffset = CGSize(width: 0, height: 20)

        guard panelSheen == nil else { return }
        let sheen = CAGradientLayer()
        sheen.name = "sheen"
        sheen.colors = [NSColor.white.withAlphaComponent(0.16).cgColor,
                        NSColor.white.withAlphaComponent(0.04).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        sheen.locations = [0, 0.35, 1]
        sheen.cornerRadius = Self.panelCorner
        sheen.cornerCurve = .continuous
        sheen.masksToBounds = true
        sheen.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "frame": NSNull()]
        panel.insertSublayer(sheen, at: 0)

        // Rim light: a gradient seen only through a hairline ring, its bright side
        // turned toward the pointer (see updateRimLights).
        let rim = CAGradientLayer()
        rim.name = "rim"
        rim.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "frame": NSNull(),
                       "colors": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]
        rim.colors = [NSColor.white.withAlphaComponent(0.6).cgColor,
                      NSColor.white.withAlphaComponent(0.1).cgColor,
                      NSColor.white.withAlphaComponent(0.2).cgColor]
        rim.locations = [0, 0.55, 1]
        let ring = PlainLayer()
        ring.borderColor = NSColor.black.cgColor
        ring.borderWidth = 1.2
        ring.cornerRadius = Self.panelCorner
        ring.cornerCurve = .continuous
        rim.mask = ring
        panel.insertSublayer(rim, above: sheen)
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
    func layoutFolderTiles(_ order: [String], animated: Bool, appear: Bool = false) {
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
                if appear {
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
