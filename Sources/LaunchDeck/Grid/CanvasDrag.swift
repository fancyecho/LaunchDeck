import AppKit
import QuartzCore

struct DragState {
    enum Source: Equatable { case grid, folder(String) }

    var item: LayoutItem
    let tile: TileLayer
    var grabOffset: CGPoint
    var source: Source
    /// Grid page the placeholder sits on, and its index there.
    var hoverPage: Int
    var insertIndex: Int
    /// Grid pages without the dragged item.
    var working: [[LayoutItem]]
    /// Folder contents without the dragged item (folder drags only).
    var folderApps: [String]
    var lastPoint: CGPoint
    var mergeTargetID: String?
    var pendingMergeID: String?
    var pendingInsert: Int?
}

/// Reserved key for the gap that opens where the dragged icon would land.
let placeholderKey = "\u{1}placeholder"
let placeholderItem = LayoutItem.app(placeholderKey)

extension LauncherCanvas {
    // MARK: - Begin

    func beginGridDrag(index: Int, at p: CGPoint) {
        guard page < pages.count, index < pages[page].count else { return }
        let item = pages[page][index]
        guard let tile = tiles[item.id] else { return }
        var working = store.pages
        working[page].remove(at: index)
        let grab = lift(tile, at: p)
        drag = DragState(item: item, tile: tile, grabOffset: grab, source: .grid, hoverPage: page,
                         insertIndex: index, working: working, folderApps: [], lastPoint: p)
        enterEditMode()
        clearHover()
    }

    func beginFolderDrag(index: Int, at p: CGPoint) {
        guard let f = folder, index < f.apps.count else { return }
        let key = f.apps[index]
        guard let tile = folderTiles["a:" + key] else { return }
        var remaining = f.apps
        remaining.remove(at: index)
        // The dragged tile now belongs to the drag, not the folder view.
        folderTiles["a:" + key] = nil
        let grab = lift(tile, at: p)
        drag = DragState(item: .app(key), tile: tile, grabOffset: grab, source: .folder(f.id), hoverPage: f.sourcePage,
                         insertIndex: index, working: store.pages, folderApps: remaining, lastPoint: p)
        enterEditMode()
        clearHover()
    }

    /// Moves the tile into the top-level drag layer and lifts it toward the pointer.
    private func lift(_ tile: TileLayer, at p: CGPoint) -> CGPoint {
        guard let parent = tile.superlayer else { return .zero }
        let pos = dragLayer.convert(Motion.currentPosition(tile), from: parent)
        tile.removeAnimation(forKey: "move")
        tile.stopJiggle()
        Motion.instantly {
            tile.removeFromSuperlayer()
            dragLayer.addSublayer(tile)
            tile.position = pos
            tile.isSelected = false
        }
        Motion.scale(tile.iconLayer, to: 1)
        tile.setLifted(true)
        Motion.scale(tile, to: 1.12, response: 0.3, damping: 0.62)
        Motion.fade(tile, to: 0.9, duration: 0.12)
        return CGPoint(x: pos.x - p.x, y: pos.y - p.y)
    }

    // MARK: - Move

    func updateDrag(to p: CGPoint) {
        guard var d = drag else { return }
        d.lastPoint = p
        drag = d
        Motion.instantly { d.tile.position = CGPoint(x: p.x + d.grabOffset.x, y: p.y + d.grabOffset.y) }

        if case .folder = d.source {
            updateFolderDrag(to: p)
            return
        }
        handleEdge(p)

        // Hit-test with the dragged icon itself, not the pointer: that's what people aim.
        let probe = iconCenter(ofDragged: d)
        let display = displayPages(d)
        let items = display[d.hoverPage]
        let slot = slotIndex(at: probe)
        if slot >= items.count {
            cancelMerge()
            scheduleReorder(min(d.working[safe: d.hoverPage]?.count ?? 0, metrics.capacity - 1))
            return
        }
        let occupant = items[slot]
        if occupant.id == placeholderItem.id {
            cancelMerge()
            cancelReorder()
            return
        }

        let c = metrics.center(for: slot)
        let target = CGPoint(x: c.x, y: c.y - TileLayer.size(for: metrics).height / 2 + metrics.iconSize / 2)
        let local = CGPoint(x: probe.x - (strip.position.x + CGFloat(d.hoverPage) * width), y: probe.y)
        let dx = local.x - target.x, dy = local.y - target.y
        let s = metrics.iconSize

        // Over the icon or its name: only ever "drop in", never shuffle, so a folder
        // can't slide away from an app on its way in.
        if abs(dx) < s * 0.55, dy > -s * 0.6, dy < s * 0.85 {
            cancelReorder()
            if d.item.folder == nil {
                scheduleMerge(occupant.id, delay: occupant.folder != nil ? 0.15 : 0.32)
            }
            return
        }
        cancelMerge()
        // Directly above or below an icon (between rows): leave things be.
        guard abs(dx) >= s * 0.55 else {
            cancelReorder()
            return
        }
        // In the gap beside an icon: make room before or after it.
        let placeholderAt = items.firstIndex(of: placeholderItem) ?? Int.max
        let working = slot < placeholderAt ? slot : slot - 1
        scheduleReorder(dx < 0 ? working : working + 1)
    }

    /// Centre of the dragged icon artwork (the tile is lifted to 1.12×).
    func iconCenter(ofDragged d: DragState) -> CGPoint {
        let pos = d.tile.position
        let lift = (metrics.iconSize / 2 - TileLayer.size(for: metrics).height / 2) * 1.12
        return CGPoint(x: pos.x, y: pos.y + lift)
    }

    /// Grid slot under the pointer on the hovered page (may exceed the item count).
    private func slotIndex(at p: CGPoint) -> Int {
        let originX = strip.position.x + CGFloat(drag?.hoverPage ?? page) * width
        let x = p.x - originX - metrics.origin.x
        let y = p.y - metrics.origin.y
        let col = min(max(Int(floor(x / metrics.cell.width)), 0), metrics.columns - 1)
        let row = min(max(Int(floor(y / metrics.cell.height)), 0), metrics.rows - 1)
        return row * metrics.columns + col
    }

    /// The working pages with the placeholder inserted and overflow cascaded, which
    /// is exactly what the user sees during the drag.
    func displayPages(_ d: DragState) -> [[LayoutItem]] {
        let cap = max(metrics.capacity, 1)
        var result = d.working
        while result.count <= d.hoverPage { result.append([]) }
        let index = min(d.insertIndex, result[d.hoverPage].count, cap - 1)
        result[d.hoverPage].insert(placeholderItem, at: index)
        var i = 0
        while i < result.count {
            while result[i].count > cap {
                let last = result[i].removeLast()
                if i + 1 < result.count { result[i + 1].insert(last, at: 0) } else { result.append([last]) }
            }
            i += 1
        }
        return result
    }

    private func scheduleReorder(_ index: Int) {
        guard let d = drag else { return }
        if index == d.insertIndex { cancelReorder(); return }
        if d.pendingInsert == index, reorderTimer != nil { return }
        reorderTimer?.invalidate()
        drag?.pendingInsert = index
        // Icons only move aside once the dragged one rests in a gap for a moment.
        reorderTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self, var d = self.drag else { return }
            d.insertIndex = index
            d.pendingInsert = nil
            self.drag = d
            self.reorderTimer = nil
            self.layoutTiles(self.displayPages(d), animated: true, skip: d.item.id)
        }
    }

    private func cancelReorder() {
        reorderTimer?.invalidate()
        reorderTimer = nil
        drag?.pendingInsert = nil
    }

    private func scheduleMerge(_ id: String, delay: TimeInterval) {
        guard let d = drag, d.mergeTargetID != id, d.pendingMergeID != id else { return }
        cancelMerge()
        drag?.pendingMergeID = id
        mergeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.drag?.pendingMergeID == id else { return }
            self.drag?.mergeTargetID = id
            if let t = self.tiles[id] {
                Motion.scale(t.iconLayer, to: 1.2, response: 0.32, damping: 0.6)
                t.isSelected = true
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func cancelMerge() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        guard let d = drag else { return }
        if let id = d.mergeTargetID, let t = tiles[id] {
            Motion.scale(t.iconLayer, to: 1)
            t.isSelected = false
        }
        drag?.mergeTargetID = nil
        drag?.pendingMergeID = nil
    }

    // MARK: - Edge paging

    private func handleEdge(_ p: CGPoint) {
        let edge: CGFloat = 36
        let dir = p.x < edge ? -1 : (p.x > width - edge ? 1 : 0)
        guard dir != 0 else {
            edgeTimer?.invalidate()
            edgeTimer = nil
            return
        }
        guard edgeTimer == nil else { return }
        edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.edgeTimer = nil
            self.flipDuringDrag(dir)
            // Keep flipping while the pointer rests at the edge.
            if let p = self.drag?.lastPoint {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, let d = self.drag, d.lastPoint == p else { return }
                    self.handleEdge(p)
                }
            }
        }
    }

    private func flipDuringDrag(_ dir: Int) {
        guard var d = drag else { return }
        let target = d.hoverPage + dir
        guard target >= 0 else { return }
        let display = displayPages(d)
        // Allow one new trailing page, but not a chain of empty ones.
        if target >= display.count, display[d.hoverPage].count <= 1 { return }
        cancelMerge()
        cancelReorder()
        while d.working.count <= target { d.working.append([]) }
        d.hoverPage = target
        d.insertIndex = min(d.working[target].count, metrics.capacity - 1)
        drag = d
        let next = displayPages(d)
        layoutTiles(next, animated: true, skip: d.item.id)
        animateStrip(to: target, count: next.count)
    }

    // MARK: - Drop

    func endDrag(at p: CGPoint) {
        guard let d = drag else { return }
        invalidateDragTimers()
        drag = nil
        defer { refreshLightMode() }

        if case .folder(let id) = d.source {
            dropInsideFolder(d, folderID: id)
            return
        }

        // Dropping onto a folder counts even if its highlight hadn't come up yet.
        let mergeID = d.mergeTargetID ?? d.pendingMergeID.flatMap { $0.hasPrefix("f:") ? $0 : nil }
        if let targetID = mergeID, let (pg, ix) = locate(targetID, in: d.working), case .app(let draggedKey) = d.item {
            var next = d.working
            let newItem: LayoutItem
            switch next[pg][ix] {
            case .folder(var f):
                f.apps.append(draggedKey)
                newItem = .folder(f)
            case .app(let key):
                newItem = .folder(Folder(id: UUID().uuidString,
                                         name: LayoutStore.suggestedFolderName(apps[key], apps[draggedKey]),
                                         apps: [key, draggedKey]))
            }
            next[pg][ix] = newItem
            if let target = tiles[targetID] {
                target.isSelected = false
                absorb(d.tile, into: dragLayer.convert(target.position, from: strip))
            } else {
                d.tile.removeFromSuperlayer()
            }
            tiles[d.item.id] = nil
            commit(next)
            if let t = tiles[newItem.id] {
                Motion.instantly { t.iconLayer.transform = CATransform3DMakeScale(1.25, 1.25, 1) }
                Motion.scale(t.iconLayer, to: 1, response: 0.4, damping: 0.55)
            }
            return
        }

        var next = displayPages(d)
        for p in next.indices {
            if let i = next[p].firstIndex(of: placeholderItem) { next[p][i] = d.item }
        }
        settle(d.tile, into: strip)
        tiles[d.item.id] = d.tile
        commit(next)
    }

    /// Drops the dragged tile back into `container`, keeping it where it is on screen.
    private func settle(_ tile: TileLayer, into container: CALayer) {
        let pos = container.convert(Motion.currentPosition(tile), from: dragLayer)
        Motion.instantly {
            tile.removeFromSuperlayer()
            container.addSublayer(tile)
            tile.position = pos
        }
        Motion.scale(tile, to: 1, response: 0.38, damping: 0.75)
        Motion.fade(tile, to: 1, duration: 0.15)
        tile.setLifted(false)
    }

    /// Shrinks the dragged icon into a folder and throws its layer away.
    private func absorb(_ tile: TileLayer, into point: CGPoint) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { tile.removeFromSuperlayer() }
        Motion.move(tile, to: point, response: 0.3, damping: 0.9)
        Motion.scale(tile, to: 0.35, response: 0.3, damping: 0.9)
        Motion.fade(tile, to: 0, duration: 0.26)
        CATransaction.commit()
    }

    /// Saves new pages and springs every tile to its final slot.
    func commit(_ newPages: [[LayoutItem]]) {
        store.setPages(cleanFolders(newPages))
        page = min(page, pageCount - 1)
        var live = Set<String>()
        for (p, items) in store.pages.enumerated() {
            for (i, item) in items.enumerated() {
                let isNew = tiles[item.id] == nil
                let t = tile(for: item)
                let target = position(page: p, slot: i)
                if isNew {
                    Motion.instantly { t.position = target }
                    t.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.2), forKey: "fade")
                } else {
                    Motion.move(t, to: target, response: 0.4, damping: 0.8)
                }
                live.insert(item.id)
            }
        }
        for (id, t) in tiles where !live.contains(id) {
            t.removeFromSuperlayer()
            tiles[id] = nil
        }
        animateStrip(to: page)
        refreshGlassTints()
        if editing { tiles.values.forEach { $0.startJiggle() } }
    }

    /// Folders emptied by a drag disappear; folders left with one app turn back into it.
    private func cleanFolders(_ pages: [[LayoutItem]]) -> [[LayoutItem]] {
        pages.map { items in
            items.compactMap { item in
                guard case .folder(let f) = item else { return item }
                if f.apps.isEmpty { return nil }
                return f.apps.count == 1 ? .app(f.apps[0]) : item
            }
        }
    }

    func locate(_ id: String, in pages: [[LayoutItem]]) -> (Int, Int)? {
        for (p, items) in pages.enumerated() {
            if let i = items.firstIndex(where: { $0.id == id }) { return (p, i) }
        }
        return nil
    }

    private func invalidateDragTimers() {
        for t in [mergeTimer, edgeTimer, reorderTimer] { t?.invalidate() }
        mergeTimer = nil
        edgeTimer = nil
        reorderTimer = nil
    }

    /// Abandons a drag without saving (used when the launcher hides mid-drag).
    func endDragImmediately() {
        guard let d = drag else { return }
        cancelMerge()
        invalidateDragTimers()
        drag = nil
        d.tile.removeFromSuperlayer()
        tiles[d.item.id] = nil
        folderTiles[d.item.id] = nil
    }

    /// Esc mid-drag: nothing is saved and everything springs back to where it was.
    func cancelDrag() {
        guard let d = drag else { return }
        let fromFolder: Bool
        if case .folder = d.source { fromFolder = true } else { fromFolder = false }
        endDragImmediately()
        if fromFolder, let f = folder, let fresh = store.folder(id: f.id) {
            refreshFolderTiles(fresh)
        }
        // Tiles shifted for the drop preview go home (folder previews are reset from
        // the saved layout too); the dragged one is recreated.
        for (p, items) in store.pages.enumerated() {
            for (i, item) in items.enumerated() {
                let isNew = tiles[item.id] == nil
                let t = tile(for: item)
                if isNew {
                    Motion.instantly { t.position = position(page: p, slot: i) }
                    t.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.2), forKey: "fade")
                } else {
                    Motion.move(t, to: position(page: p, slot: i))
                }
            }
        }
        animateStrip(to: min(page, pageCount - 1))
        if editing { tiles.values.forEach { $0.startJiggle() } }
        refreshLightMode()
    }

    // MARK: - Folder drags

    private func updateFolderDrag(to p: CGPoint) {
        guard var d = drag, let f = folder else { return }
        if panel.frame.insetBy(dx: -24, dy: -24).contains(p) {
            let local = folderStrip.convert(p, from: root)
            let cell = f.metrics.cell
            let col = min(max(Int(floor(local.x / cell.width)), 0), f.columns - 1)
            let row = min(max(Int(floor(local.y / cell.height)), 0), max(f.rows - 1, 0))
            let index = min(row * f.columns + col, d.folderApps.count)
            guard index != d.insertIndex else { return }
            d.insertIndex = index
            drag = d
            var order = d.folderApps
            order.insert(placeholderKey, at: index)
            layoutFolderTiles(order, animated: true)
        } else {
            transferOutOfFolder(at: p)
        }
    }

    /// Dragging an app past the folder's edge closes the folder and carries the app
    /// onto the grid, like Launchpad.
    private func transferOutOfFolder(at p: CGPoint) {
        guard var d = drag, case .folder(let id) = d.source else { return }
        var working = store.pages
        if let (pg, ix) = locate("f:" + id, in: working), case .folder(var f) = working[pg][ix] {
            f.apps = d.folderApps
            working[pg][ix] = .folder(f)
            if let t = tiles["f:" + id] { configure(t, .folder(f)) }
        }
        d.working = working
        d.source = .grid
        d.hoverPage = page
        drag = d
        // Grow back to grid size now that it's leaving the folder.
        configure(d.tile, d.item)
        closeFolder(animated: true)
        // Compute first: slotIndex reads `drag`, which can't be read while being written.
        let slot = slotIndex(at: p)
        drag?.insertIndex = min(slot, working[safe: page]?.count ?? 0, metrics.capacity - 1)
        if let d = drag { layoutTiles(displayPages(d), animated: true, skip: d.item.id) }
    }

    private func dropInsideFolder(_ d: DragState, folderID: String) {
        guard case .app(let key) = d.item else { return }
        var order = d.folderApps
        order.insert(key, at: min(d.insertIndex, order.count))
        store.updateFolder(id: folderID) { $0.apps = order }
        folder?.apps = order
        settle(d.tile, into: folderStrip)
        folderTiles["a:" + key] = d.tile
        layoutFolderTiles(order, animated: true)
        if editing { d.tile.startJiggle() }
        if let f = store.folder(id: folderID), let t = tiles["f:" + folderID] { configure(t, .folder(f)) }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
