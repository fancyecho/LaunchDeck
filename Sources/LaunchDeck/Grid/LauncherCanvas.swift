import AppKit
import QuartzCore

/// The launcher surface, drawn entirely with Core Animation. Paging moves a single
/// layer and every tile is a pre-rendered bitmap, so swipes stay at display rate.
///
/// Split across files: this one has layout, paging, show/hide and input routing;
/// CanvasDrag, CanvasFolder and CanvasSearch add the rest.
final class LauncherCanvas: NSView {
    let chrome: ChromeState
    let store = LayoutStore()
    var dismissHandler: (() -> Void)?
    var launchHandler: ((AppItem) -> Void)?
    var metricsChanged: ((GridMetrics) -> Void)?

    var apps: [String: AppItem] = [:]
    var catalogOrder: [AppItem] = []
    var metrics = GridMetrics.zero
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsLayout = true } }
    }

    // Layer tree (y grows downward).
    let root = PlainLayer()
    let backdrop = PlainLayer()
    /// Everything above the wallpaper; scaled and faded as one when opening/closing.
    let stage = PlainLayer()
    let gridContainer = PlainLayer()
    /// Blurred snapshot of the grid shown behind an open folder.
    let blurLayer = PlainLayer()
    let scrim = PlainLayer()
    /// Soft diffuse light under the pointer while it rests on an icon.
    let pointerLight = CAGradientLayer()
    /// Comet with a tail that follows the pointer over empty space.
    let comet = CometTrail()
    var cometLink: CADisplayLink?
    var pointerInside = true
    let strip = PlainLayer()
    let dotsLayer = PlainLayer()
    let resultsLayer = PlainLayer()
    let folderLayer = PlainLayer()
    let panel = PlainLayer()
    let panelTitle = PlainLayer()
    let panelContent = PlainLayer()
    let folderStrip = PlainLayer()
    let dragLayer = PlainLayer()

    var tiles: [String: TileLayer] = [:]
    var resultTiles: [String: TileLayer] = [:]
    var folderTiles: [String: TileLayer] = [:]
    var dotLayers: [PlainLayer] = []

    let usage = UsageStore()
    var runningKeys = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []

    /// System "Reduce motion": no tilt, parallax or ripple, just fades.
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Light effects.
    var sampler: WallpaperSampler?
    weak var hoveredTile: TileLayer?
    var lastPointer: CGPoint?

    // Browsing state.
    var page = 0
    var selection: Int?
    var editing = false
    var isShown = false
    var results: [AppItem] = []

    // Trackpad paging.
    var scrollDragging = false
    var rawOffset: CGFloat = 0
    var samples: [(t: TimeInterval, dx: CGFloat)] = []
    var lastWheelFlip: TimeInterval = 0

    // Mouse.
    enum PressTarget: Equatable {
        case gridItem(Int), folderItem(Int), result(Int), dot(Int), folderTitle, background, panelBackground
    }
    struct Press {
        var point: CGPoint
        var target: PressTarget
        var consumed = false
    }
    var press: Press?
    var longPressTimer: Timer?

    // Drag & drop (CanvasDrag.swift).
    var drag: DragState?
    var mergeTimer: Timer?
    var edgeTimer: Timer?
    var reorderTimer: Timer?

    // Open folder (CanvasFolder.swift).
    var folder: OpenFolder?
    var titleField: NSTextField?

    init(chrome: ChromeState) {
        self.chrome = chrome
        super.init(frame: .zero)
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true
        layerUsesCoreImageFilters = true

        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.opacity = 0
        strip.anchorPoint = .zero
        resultsLayer.opacity = 0
        panelContent.masksToBounds = true
        panelContent.addSublayer(folderStrip)
        panel.addSublayer(panelTitle)
        panel.addSublayer(panelContent)
        folderLayer.addSublayer(panel)
        folderLayer.isHidden = true

        blurLayer.contentsGravity = .resize
        blurLayer.opacity = 0
        // Barely-there dimming: enough focus on an open folder without greying the wallpaper.
        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.05).cgColor
        scrim.opacity = 0

        pointerLight.type = .radial
        pointerLight.startPoint = CGPoint(x: 0.5, y: 0.5)
        pointerLight.endPoint = CGPoint(x: 1, y: 1)
        pointerLight.colors = [NSColor.white.withAlphaComponent(0.2).cgColor,
                               NSColor.white.withAlphaComponent(0.07).cgColor,
                               NSColor.white.withAlphaComponent(0).cgColor]
        pointerLight.locations = [0, 0.38, 1]
        pointerLight.bounds = CGRect(x: 0, y: 0, width: 960, height: 960)
        pointerLight.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        pointerLight.opacity = 0
        comet.opacity = 0

        root.addSublayer(backdrop)
        root.addSublayer(stage)
        stage.addSublayer(pointerLight)
        stage.addSublayer(blurLayer)
        stage.addSublayer(gridContainer)
        gridContainer.addSublayer(strip)
        gridContainer.addSublayer(dotsLayer)
        stage.addSublayer(scrim)
        stage.addSublayer(resultsLayer)
        stage.addSublayer(folderLayer)
        root.addSublayer(dragLayer)
        root.insertSublayer(comet, below: dragLayer)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshRunning()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var width: CGFloat { metrics.size.width }
    var pages: [[LayoutItem]] { store.pages }
    var pageCount: Int { max(1, store.pages.count) }
    var isSearching: Bool { !chrome.query.isEmpty }
    var isEditingText: Bool { titleField != nil }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let m = GridMetrics(size: bounds.size, topInset: topInset)
        guard m != metrics, bounds.width > 0 else { return }
        metrics = m
        Motion.instantly {
            for l in [stage, gridContainer, blurLayer, scrim, resultsLayer, folderLayer, dragLayer, dotsLayer] {
                l.frame = bounds
            }
            strip.bounds = bounds
            // Wider than the screen so it can drift for parallax while paging.
            backdrop.bounds = CGRect(x: 0, y: 0, width: bounds.width + Self.parallaxRange + 80, height: bounds.height)
            backdrop.position = CGPoint(x: backdropX(forStripX: -CGFloat(page) * bounds.width), y: bounds.midY)
        }
        Motion.instantly { pointerLight.position = lastPointer ?? CGPoint(x: bounds.midX, y: bounds.midY) }
        store.capacity = m.capacity
        rebuildTiles()
        snapStrip()
        if isSearching { layoutResults(animated: false) }
        metricsChanged?(m)
    }

    func setApps(_ items: [AppItem]) {
        apps = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        catalogOrder = items
        guard drag == nil else { return }  // never yank tiles mid-drag; next scan catches up
        store.sync(with: items)
        rebuildTiles()
        snapStrip()
        if isSearching { updateResults() }
        if let f = folder, let fresh = store.folder(id: f.id) { refreshFolderTiles(fresh) }
    }

    func setWallpaper(_ image: CGImage?) {
        Motion.instantly {
            backdrop.contents = image
            // Without a wallpaper the system blur shows windows behind; darken it so
            // they don't compete with the icons.
            backdrop.backgroundColor = image == nil ? NSColor.black.withAlphaComponent(0.38).cgColor : nil
        }
        sampler = image.flatMap(WallpaperSampler.init)
        refreshGlassTints()
    }

    /// Re-tints every folder's glass from the wallpaper behind its slot.
    func refreshGlassTints() {
        for items in store.pages {
            for (i, item) in items.enumerated() where item.folder != nil {
                guard let t = tiles[item.id] else { continue }
                t.setGlassTint(glassTint(slot: i))
            }
        }
    }

    func glassTint(slot: Int) -> CGColor {
        guard let sampler else { return NSColor.white.withAlphaComponent(0.16).cgColor }
        return sampler.glassTint(at: metrics.center(for: slot), in: metrics.size)
    }

    var hasWallpaper: Bool { backdrop.contents != nil }

    /// Called before the first wallpaper arrives so the fallback dimming applies.
    func ensureBackdropFallback() {
        if backdrop.contents == nil { setWallpaper(nil) }
    }

    /// Creates, updates and positions tiles for the saved layout; drops stale ones.
    func rebuildTiles() {
        guard metrics.capacity > 0, metrics.size.width > 0 else { return }
        var live = Set<String>()
        for (p, items) in store.pages.enumerated() {
            for (i, item) in items.enumerated() {
                let t = tile(for: item)
                live.insert(item.id)
                Motion.instantly { t.position = position(page: p, slot: i) }
            }
        }
        for (id, t) in tiles where !live.contains(id) {
            t.removeFromSuperlayer()
            tiles[id] = nil
        }
        page = min(page, pageCount - 1)
        updateDots()
        refreshGlassTints()
        if editing { tiles.values.forEach { $0.startJiggle() } }
    }

    @discardableResult
    func tile(for item: LayoutItem) -> TileLayer {
        let t: TileLayer
        if let existing = tiles[item.id] {
            t = existing
        } else {
            t = TileLayer(itemID: item.id)
            strip.addSublayer(t)
            tiles[item.id] = t
        }
        configure(t, item)
        return t
    }

    func configure(_ t: TileLayer, _ item: LayoutItem, metrics m: GridMetrics? = nil) {
        let m = m ?? metrics
        switch item {
        case .app(let key):
            let app = apps[key]
            t.configure(content: .app(icon: app?.icon), label: app?.name ?? "", metrics: m, tint: app?.tint,
                        badge: store.fresh.contains(key))
            t.setRunning(runningKeys.contains(key))
        case .folder(let f):
            t.configure(content: .folder(icons: f.apps.prefix(9).map { apps[$0]?.icon }), label: f.name, metrics: m,
                        tint: NSColor(white: 1, alpha: 1).cgColor, badge: f.apps.contains { store.fresh.contains($0) })
        }
    }

    func position(page p: Int, slot: Int) -> CGPoint {
        let c = metrics.center(for: slot)
        return CGPoint(x: CGFloat(p) * width + c.x, y: c.y)
    }

    /// Springs every tile to its slot in `pages`, which may be a drag preview.
    func layoutTiles(_ pages: [[LayoutItem]], animated: Bool, skip: String? = nil) {
        for (p, items) in pages.enumerated() {
            for (i, item) in items.enumerated() where item.id != skip {
                guard let t = tiles[item.id] else { continue }
                let target = position(page: p, slot: i)
                if animated {
                    if t.position != target || t.animation(forKey: "move") != nil { Motion.move(t, to: target) }
                } else {
                    Motion.instantly { t.position = target }
                }
            }
        }
    }

    // MARK: - Page dots

    func updateDots(count: Int? = nil) {
        let n = count ?? pageCount
        while dotLayers.count < n {
            let d = PlainLayer()
            d.backgroundColor = NSColor.white.cgColor
            d.cornerRadius = 4
            dotsLayer.addSublayer(d)
            dotLayers.append(d)
        }
        while dotLayers.count > n { dotLayers.removeLast().removeFromSuperlayer() }
        let spacing: CGFloat = 18
        let startX = width / 2 - CGFloat(n - 1) * spacing / 2
        Motion.instantly {
            for (i, d) in dotLayers.enumerated() {
                d.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
                d.position = CGPoint(x: startX + CGFloat(i) * spacing, y: metrics.dotsY)
                d.isHidden = n <= 1
            }
        }
        for (i, d) in dotLayers.enumerated() {
            Motion.fade(d, to: i == page ? 0.95 : 0.32, duration: 0.18)
        }
    }

    /// Lets the page indicator slide between dots while a swipe is in progress.
    func updateDotProgress(_ position: CGFloat) {
        for (i, d) in dotLayers.enumerated() {
            d.removeAnimation(forKey: "fade")
            let weight = max(0, 1 - abs(CGFloat(i) - position))
            Motion.instantly { d.opacity = Float(0.32 + 0.63 * weight) }
        }
    }

    func dotIndex(at p: CGPoint) -> Int? {
        guard dotLayers.count > 1, abs(p.y - metrics.dotsY) < 14 else { return nil }
        for (i, d) in dotLayers.enumerated() where abs(d.position.x - p.x) < 9 { return i }
        return nil
    }

    // MARK: - Paging

    func snapStrip() {
        strip.removeAnimation(forKey: "page")
        backdrop.removeAnimation(forKey: "parallax")
        Motion.instantly {
            strip.position = CGPoint(x: -CGFloat(page) * width, y: 0)
            backdrop.position.x = backdropX(forStripX: strip.position.x)
        }
    }

    // MARK: - Parallax

    static let parallaxRange: CGFloat = 70

    /// The wallpaper drifts a fraction of the strip's travel, so pages feel like
    /// they slide over a deeper layer. Total drift is capped at `parallaxRange`.
    func backdropX(forStripX x: CGFloat) -> CGFloat {
        let center = width / 2
        guard !reduceMotion, pageCount > 1, width > 0 else { return center }
        let k = min(0.035, Self.parallaxRange / (CGFloat(pageCount - 1) * width))
        return center + Self.parallaxRange / 2 + x * k
    }

    /// Current on-screen strip x, including any in-flight spring.
    var liveStripX: CGFloat { strip.presentation()?.position.x ?? strip.position.x }

    func animateStrip(to target: Int, velocity: CGFloat = 0, count: Int? = nil) {
        let n = count ?? pageCount
        let t = min(max(target, 0), n - 1)
        let from = liveStripX
        let to = -CGFloat(t) * width
        strip.removeAnimation(forKey: "page")
        Motion.instantly { strip.position = CGPoint(x: to, y: 0) }
        let distance = to - from
        if abs(distance) > 0.5 {
            let v = abs(distance) > 20 ? max(-25, min(25, velocity / distance)) : 0
            strip.add(Motion.spring("position.x", from: from, to: to, response: 0.44, damping: 0.9, velocity: v),
                      forKey: "page")
        }
        let bFrom = backdrop.presentation()?.position.x ?? backdrop.position.x
        let bTo = backdropX(forStripX: to)
        backdrop.removeAnimation(forKey: "parallax")
        Motion.instantly { backdrop.position.x = bTo }
        if abs(bTo - bFrom) > 0.2 {
            backdrop.add(Motion.spring("position.x", from: bFrom, to: bTo, response: 0.44, damping: 0.9), forKey: "parallax")
        }
        if t != page { selection = nil; refreshSelection() }
        page = t
        updateDots(count: n)
    }

    func goTo(page target: Int) {
        animateStrip(to: target)
    }

    func handleScroll(_ event: NSEvent) {
        if folder != nil { scrollFolder(event); return }
        guard isShown, !isSearching, drag == nil, width > 0 else { return }

        guard event.hasPreciseScrollingDeltas else {
            let d = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            if abs(d) > 0.1, event.timestamp - lastWheelFlip > 0.3 {
                lastWheelFlip = event.timestamp
                goTo(page: page + (d < 0 ? 1 : -1))
            }
            return
        }
        if !event.momentumPhase.isEmpty { return }

        if event.phase.contains(.began) || (!scrollDragging && event.phase.contains(.changed)) {
            // Catch the strip wherever it is, even mid-spring, so swipes chain smoothly.
            let current = liveStripX
            strip.removeAnimation(forKey: "page")
            backdrop.removeAnimation(forKey: "parallax")
            Motion.instantly {
                strip.position.x = current
                backdrop.position.x = backdropX(forStripX: current)
            }
            rawOffset = current + CGFloat(page) * width
            scrollDragging = true
            clearHover()
            samples.removeAll()
        }
        if scrollDragging, event.phase.contains(.changed) || event.phase.contains(.began) {
            let dx = event.scrollingDeltaX
            if abs(dx) >= abs(event.scrollingDeltaY) * 0.5 || rawOffset != 0 {
                rawOffset += dx
                samples.append((event.timestamp, dx))
                samples.removeAll { event.timestamp - $0.t > 0.08 }
                Motion.instantly {
                    strip.position.x = -CGFloat(page) * width + rubberBand(rawOffset)
                    backdrop.position.x = backdropX(forStripX: strip.position.x)
                }
                updateDotProgress(-strip.position.x / width)
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            guard scrollDragging else { return }
            scrollDragging = false
            let span = max((samples.last?.t ?? 0) - (samples.first?.t ?? 0), 1.0 / 120)
            let velocity = samples.count > 1 ? samples.reduce(0) { $0 + $1.dx } / CGFloat(span) : 0
            let offset = strip.position.x + CGFloat(page) * width
            let projected = offset + velocity * 0.15
            var target = page
            if projected < -width * 0.2 { target += 1 }
            if projected > width * 0.2 { target -= 1 }
            samples.removeAll()
            animateStrip(to: target, velocity: velocity)
        }
    }

    private func rubberBand(_ offset: CGFloat) -> CGFloat {
        let maxOffset = CGFloat(page) * width
        let minOffset = -CGFloat(pageCount - 1 - page) * width
        func damp(_ x: CGFloat) -> CGFloat {
            let d = width * 0.5
            return (1 - 1 / (abs(x) * 0.55 / d + 1)) * d * (x < 0 ? -1 : 1)
        }
        if offset > maxOffset { return maxOffset + damp(offset - maxOffset) }
        if offset < minOffset { return minOffset + damp(offset - minOffset) }
        return offset
    }

    // MARK: - Show / hide

    /// `interactive` skips the icon ripple: a pinch drives the reveal instead.
    func prepareForShow(topInset inset: CGFloat, interactive: Bool = false) {
        topInset = inset
        layoutSubtreeIfNeeded()
        closeFolder(animated: false)
        exitEditMode()
        setQuery("")
        selection = nil
        refreshSelection()
        TileLayer.reduceMotion = reduceMotion
        refreshRunning()
        rebuildTiles()
        snapStrip()
        clearHover()
        if let w = window {
            // Start the light where the pointer already is.
            lastPointer = nil
            let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            movePointerLight(to: p)
            updateRimLights(toward: p)
            comet.showsTail = !reduceMotion
            comet.reset(at: p)
            pointerInside = bounds.contains(p)
        }
        for l in [stage, gridContainer, resultsLayer, backdrop, dragLayer] { l.removeAllAnimations() }
        Motion.instantly {
            gridContainer.opacity = 1
            gridContainer.transform = CATransform3DIdentity
            backdrop.opacity = 0
            if interactive {
                stage.opacity = 0
                stage.transform = CATransform3DMakeScale(1.12, 1.12, 1)
                dotsLayer.opacity = 1
            } else {
                stage.opacity = 1
                stage.transform = CATransform3DIdentity
                if page < pages.count {
                    for item in pages[page] { tiles[item.id]?.opacity = 0 }
                }
                dotsLayer.opacity = 0
            }
        }
    }

    // MARK: - Pinch-driven presentation

    /// Draws the launcher partway open (0 hidden, 1 open) while fingers are moving.
    func setPresentation(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        for l in [stage, backdrop] {
            l.removeAnimation(forKey: "fade")
            l.removeAnimation(forKey: "scale")
            l.removeAnimation(forKey: "zoom")
            l.removeAnimation(forKey: "zoomOut")
        }
        Motion.instantly {
            stage.opacity = Float(p)
            let s = 1.12 - 0.12 * p
            stage.transform = CATransform3DMakeScale(s, s, 1)
            backdrop.opacity = Float(min(1, p * 1.4))
            let b = 1.045 - 0.045 * p
            backdrop.transform = CATransform3DMakeScale(b, b, 1)
        }
    }

    /// Springs from wherever the pinch left things to fully open (or back closed).
    func finishPresentation(open: Bool) {
        let p: CGFloat = open ? 1 : 0
        Motion.scale(stage, to: 1.12 - 0.12 * p, response: 0.42, damping: 0.86)
        Motion.fade(stage, to: Float(p), duration: open ? 0.2 : 0.18)
        Motion.scale(backdrop, to: 1.045 - 0.045 * p, response: 0.5, damping: 1)
        Motion.fade(backdrop, to: Float(p), duration: 0.24)
        if open {
            isShown = true
            chrome.isShown = true
        }
        refreshLightMode()
    }

    func animateIn() {
        isShown = true
        chrome.isShown = true
        refreshLightMode()
        let now = CACurrentMediaTime()
        Motion.fade(backdrop, to: 1, duration: 0.34)
        backdrop.add(Motion.basic("transform.scale", from: 1.045, to: 1, duration: 0.5), forKey: "zoom")

        // Icons land from slightly in front, centre first, rippling outward.
        if page < pages.count {
            for (i, item) in pages[page].enumerated() {
                guard let t = tiles[item.id] else { continue }
                let begin = now + (reduceMotion ? 0 : metrics.rippleDelay(for: i))
                Motion.instantly { t.opacity = 1 }
                let fade = Motion.basic("opacity", from: 0, to: 1, duration: 0.26)
                fade.beginTime = begin
                fade.fillMode = .backwards
                t.add(fade, forKey: "appearFade")
                let pop = Motion.spring("transform.scale", from: reduceMotion ? 1 : 1.22, to: 1, response: 0.5, damping: 0.74)
                pop.beginTime = begin
                pop.fillMode = .backwards
                t.add(pop, forKey: "appearScale")
            }
        }
        let dots = Motion.basic("opacity", from: 0, to: 1, duration: 0.3)
        dots.beginTime = now + 0.12
        dots.fillMode = .backwards
        Motion.instantly { dotsLayer.opacity = 1 }
        dotsLayer.add(dots, forKey: "fade")
    }

    func animateOut(launching key: String?) {
        isShown = false
        chrome.isShown = false
        refreshLightMode()
        endDragImmediately()

        // The launched icon swells and dissolves on its own, above everything else.
        if let key, let t = (folderTiles["a:" + key] ?? resultTiles["r:" + key] ?? tiles["a:" + key]),
           let parent = t.superlayer {
            let p = dragLayer.convert(t.position, from: parent)
            t.removeAllAnimations()
            Motion.instantly {
                t.removeFromSuperlayer()
                dragLayer.addSublayer(t)
                t.position = p
            }
            bloom(at: CGPoint(x: p.x, y: p.y - TileLayer.size(for: metrics).height / 2 + metrics.iconSize / 2),
                  color: apps[key]?.tint ?? NSColor.white.cgColor, below: t)
            Motion.fade(t, to: 0, duration: 0.34)
            t.add(Motion.basic("transform.scale", from: 1, to: 1.45, duration: 0.34), forKey: "launch")
            Motion.instantly { t.transform = CATransform3DMakeScale(1.45, 1.45, 1) }
        }

        Motion.fade(stage, to: 0, duration: 0.22)
        Motion.scaleBasic(stage, to: 1.08, duration: 0.24, timing: .easeIn)
        Motion.fade(backdrop, to: 0, duration: 0.28)
    }

    /// Restores the resting layer state once the window is off screen.
    func resetAfterHide() {
        for l in [stage, gridContainer, resultsLayer, folderLayer, backdrop, blurLayer, scrim] { l.removeAllAnimations() }
        Motion.instantly {
            for l in [stage, gridContainer, folderLayer] {
                l.opacity = 1
                l.transform = CATransform3DIdentity
            }
            resultsLayer.opacity = 0
            resultsLayer.transform = CATransform3DIdentity
            for t in dragLayer.sublayers ?? [] { t.removeFromSuperlayer() }
        }
        // Launched tiles were lifted out of the strip; recreate them in place.
        for (id, t) in tiles where t.superlayer !== strip {
            tiles[id] = nil
        }
        for (id, t) in resultTiles where t.superlayer !== resultsLayer { resultTiles[id] = nil }
        for (id, t) in folderTiles where t.superlayer !== folderStrip { folderTiles[id] = nil }
        closeFolder(animated: false)
        setQuery("")
        exitEditMode()
        clearHover()
        rebuildTiles()
    }

    // MARK: - Edit mode

    func enterEditMode() {
        guard !editing else { return }
        editing = true
        for t in tiles.values where t.itemID != drag?.item.id { t.startJiggle() }
        for t in folderTiles.values where t.itemID != drag?.item.id { t.startJiggle() }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    func exitEditMode() {
        guard editing else { return }
        editing = false
        tiles.values.forEach { $0.stopJiggle() }
        folderTiles.values.forEach { $0.stopJiggle() }
    }

    // MARK: - Mouse

    func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    func gridIndex(at p: CGPoint) -> Int? {
        guard page < pages.count else { return nil }
        let originX = strip.position.x + CGFloat(page) * width
        let local = CGPoint(x: p.x - originX, y: p.y)
        let size = TileLayer.size(for: metrics)
        for i in pages[page].indices {
            let c = metrics.center(for: i)
            let hit = CGRect(x: c.x - metrics.iconSize * 0.62, y: c.y - size.height / 2,
                             width: metrics.iconSize * 1.24, height: size.height)
            if hit.contains(local) { return i }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isShown else { return }
        let p = point(event)
        if titleField != nil { finishRenaming() }

        let target: PressTarget
        if folder != nil {
            if let i = folderIndex(at: p) {
                target = .folderItem(i)
            } else if folderTitleFrame.contains(p) {
                target = .folderTitle
            } else if panel.frame.contains(p) {
                target = .panelBackground
            } else {
                target = .background
            }
        } else if isSearching {
            target = resultIndex(at: p).map { .result($0) } ?? .background
        } else if let i = gridIndex(at: p) {
            target = .gridItem(i)
        } else if let d = dotIndex(at: p) {
            target = .dot(d)
        } else {
            target = .background
        }
        press = Press(point: p, target: target)

        if let t = pressedTile(target), !editing {
            Motion.scale(t.iconLayer, to: 0.9, response: 0.22, damping: 0.7)
        }
        longPressTimer?.invalidate()
        if case .gridItem = target { scheduleLongPress() }
        if case .folderItem = target { scheduleLongPress() }
    }

    private func scheduleLongPress() {
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, self.drag == nil, var press = self.press else { return }
            press.consumed = true
            self.press = press
            if let t = self.pressedTile(press.target) { Motion.scale(t.iconLayer, to: 1) }
            self.enterEditMode()
        }
    }

    func pressedTile(_ target: PressTarget) -> TileLayer? {
        switch target {
        case .gridItem(let i): return page < pages.count && i < pages[page].count ? tiles[pages[page][i].id] : nil
        case .folderItem(let i): return folder.flatMap { i < $0.apps.count ? folderTiles["a:" + $0.apps[i]] : nil }
        case .result(let i): return i < results.count ? resultTiles["r:" + results[i].key] : nil
        default: return nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        movePointerLight(to: p)
        feedComet(p)
        if drag != nil {
            updateDrag(to: p)
            return
        }
        guard let press, hypot(p.x - press.point.x, p.y - press.point.y) > 5 else { return }
        longPressTimer?.invalidate()
        switch press.target {
        case .gridItem(let i): beginGridDrag(index: i, at: p)
        case .folderItem(let i): beginFolderDrag(index: i, at: p)
        default: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        let p = point(event)
        defer { press = nil }
        if drag != nil {
            endDrag(at: p)
            return
        }
        guard let press else { return }
        if let t = pressedTile(press.target) { Motion.scale(t.iconLayer, to: 1) }
        if press.consumed { return }
        let moved = hypot(p.x - press.point.x, p.y - press.point.y) > 5

        switch press.target {
        case .gridItem(let i):
            guard !moved, i < pages[page].count else { return }
            let item = pages[page][i]
            if editing, item.folder == nil { exitEditMode(); return }
            activate(item)
        case .folderItem(let i):
            guard !moved, let f = folder, i < f.apps.count else { return }
            if editing { exitEditMode(); return }
            if let app = apps[f.apps[i]] { launch(app) }
        case .result(let i):
            if !moved, i < results.count { launch(results[i]) }
        case .dot(let d):
            goTo(page: d)
        case .folderTitle:
            beginRenaming()
        case .panelBackground:
            if editing { exitEditMode() }
        case .background:
            if folder != nil {
                closeFolder(animated: true)
            } else if editing {
                exitEditMode()
            } else {
                dismissHandler?()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isShown, drag == nil else { return }
        if showItemMenu(for: event) { return }
        let menu = NSMenu()
        if let release = Updater.shared.available {
            menu.addItem(ClosureMenuItem(L10n.t("Update to \(release.version)…", "更新到 \(release.version)…")) { [weak self] in
                Updater.shared.promptToInstall(release, above: self?.window)
            })
            menu.addItem(.separator())
        }
        if !store.hidden.isEmpty {
            menu.addItem(ClosureMenuItem(L10n.t("Show \(store.hidden.count) Hidden App(s)", "显示已隐藏的 \(store.hidden.count) 个应用")) {
                [weak self] in self?.unhideAll()
            })
            menu.addItem(.separator())
        }
        if editing {
            menu.addItem(withTitle: L10n.t("Done Editing", "完成编辑"), action: #selector(menuExitEdit), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: L10n.t("Edit Layout", "编辑布局"), action: #selector(menuEnterEdit), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("Reset Layout by Category…", "按类别重新整理（重置布局）…"),
                     action: #selector(menuResetLayout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = ClosureMenuItem(L10n.t("Open at Login", "登录时打开")) { LoginItem.toggle() }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(ClosureMenuItem(L10n.t("Check for Updates…", "检查更新…")) { [weak self] in
            Updater.shared.checkInteractively(above: self?.window)
        })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuEnterEdit() { enterEditMode() }
    @objc private func menuExitEdit() { exitEditMode() }

    @objc private func menuResetLayout() { confirmResetLayout() }

    func confirmResetLayout() {
        let alert = NSAlert()
        alert.messageText = L10n.t("Reset the layout?", "重置布局？")
        alert.informativeText = L10n.t(
            "Apple apps go on the first page and other apps are grouped into folders by category. Your current arrangement will be lost.",
            "系统应用放在第一页，其余应用按类别归入文件夹。当前的自定义排列会被覆盖。")
        alert.addButton(withTitle: L10n.t("Reset", "重置"))
        alert.addButton(withTitle: L10n.t("Cancel", "取消"))
        alert.window.level = NSWindow.Level(rawValue: (window?.level.rawValue ?? 0) + 1)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        closeFolder(animated: false)
        store.resetToDefault(apps: catalogOrder)
        page = 0
        rebuildTiles()
        snapStrip()
    }

    func activate(_ item: LayoutItem) {
        switch item {
        case .app(let key): if let app = apps[key] { launch(app) }
        case .folder(let f): openFolder(f)
        }
    }

    func launch(_ app: AppItem) {
        guard isShown else { return }
        usage.recordLaunch(app.key)
        store.markOpened(app.key)
        launchHandler?(app)
    }

    /// Bundle IDs (or paths) of running apps, for the Dock-style dots.
    func refreshRunning() {
        runningKeys = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier ?? $0.bundleURL?.path })
        for (id, t) in tiles where id.hasPrefix("a:") { t.setRunning(runningKeys.contains(String(id.dropFirst(2)))) }
        for (id, t) in folderTiles { t.setRunning(runningKeys.contains(String(id.dropFirst(2)))) }
        for (id, t) in resultTiles { t.setRunning(runningKeys.contains(String(id.dropFirst(2)))) }
    }

    // MARK: - Keyboard

    /// Returns true when the event was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isShown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53:  // esc
            if drag != nil { cancelDrag() }
            else if folder != nil { closeFolder(animated: true) }
            else if isSearching { setQuery("") }
            else if editing { exitEditMode() }
            else { dismissHandler?() }
            return true
        case 36, 76:  // return, enter
            activateSelection()
            return true
        case 51:  // delete
            if mods.contains(.command) {
                setQuery("")
            } else if mods.contains(.option) {
                var q = chrome.query
                while q.last == " " { q.removeLast() }
                while let last = q.last, last != " " { q.removeLast() }
                setQuery(q)
            } else if !chrome.query.isEmpty {
                setQuery(String(chrome.query.dropLast()))
            }
            return true
        case 123: moveSelection(dx: -1, dy: 0); return true
        case 124: moveSelection(dx: 1, dy: 0); return true
        case 125: moveSelection(dx: 0, dy: 1); return true
        case 126: moveSelection(dx: 0, dy: -1); return true
        case 48: moveSelection(dx: mods.contains(.shift) ? -1 : 1, dy: 0); return true
        default: break
        }

        if mods.contains(.command) {
            if event.charactersIgnoringModifiers?.lowercased() == "v",
               let text = NSPasteboard.general.string(forType: .string) {
                setQuery(chrome.query + text.components(separatedBy: .newlines).joined(separator: " "))
                return true
            }
            return false
        }
        if mods.contains(.control) { return false }

        // Raw characters, before any input method: "wx" with a Chinese IME on still searches pinyin.
        guard let chars = event.characters else { return false }
        let scalars = chars.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
        guard !scalars.isEmpty else { return false }
        let text = String(String.UnicodeScalarView(scalars))
        if chrome.query.isEmpty, text.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if folder != nil { closeFolder(animated: true) }
        exitEditMode()
        setQuery(chrome.query + text)
        return true
    }

    /// Number of items and columns in whatever the keyboard is navigating.
    private var navigationContext: (count: Int, columns: Int) {
        if let f = folder { return (f.apps.count, f.columns) }
        if isSearching { return (min(results.count, metrics.capacity), metrics.columns) }
        return (page < pages.count ? pages[page].count : 0, metrics.columns)
    }

    private func moveSelection(dx: Int, dy: Int) {
        let (count, cols) = navigationContext
        guard count > 0 else { return }
        guard let current = selection else {
            selection = 0
            refreshSelection()
            return
        }
        var next = current + dx + dy * cols
        if folder == nil, !isSearching, dx != 0 {
            // Walking off the side of a page continues on the neighbouring page.
            if next >= count, page + 1 < pageCount {
                goTo(page: page + 1)
                selection = 0
                refreshSelection()
                return
            }
            if next < 0, page > 0 {
                goTo(page: page - 1)
                selection = max(0, (page < pages.count ? pages[page].count : 1) - 1)
                refreshSelection()
                return
            }
        }
        if dy != 0, next < 0 || next >= count { next = current }
        selection = min(max(next, 0), count - 1)
        refreshSelection()
    }

    func refreshSelection() {
        let selectedID: String?
        if let f = folder {
            selectedID = selection.flatMap { $0 < f.apps.count ? "a:" + f.apps[$0] : nil }
            for (id, t) in folderTiles { t.isSelected = id == selectedID }
            return
        }
        if isSearching {
            selectedID = selection.flatMap { $0 < results.count ? "r:" + results[$0].key : nil }
            for (id, t) in resultTiles { t.isSelected = id == selectedID }
            return
        }
        selectedID = selection.flatMap { page < pages.count && $0 < pages[page].count ? pages[page][$0].id : nil }
        for (id, t) in tiles { t.isSelected = id == selectedID }
    }

    private func activateSelection() {
        if let f = folder {
            if let s = selection, s < f.apps.count, let app = apps[f.apps[s]] { launch(app) }
        } else if isSearching {
            if !results.isEmpty { launch(results[min(selection ?? 0, results.count - 1)]) }
        } else if let s = selection, page < pages.count, s < pages[page].count {
            activate(pages[page][s])
        }
    }
}
