import AppKit
import QuartzCore

extension LauncherCanvas {
    func setQuery(_ q: String) {
        guard q != chrome.query else { return }
        let wasSearching = isSearching
        chrome.query = q
        if isSearching != wasSearching {
            Motion.fade(gridContainer, to: isSearching ? 0 : 1, duration: isSearching ? 0.16 : 0.22)
            Motion.fade(resultsLayer, to: isSearching ? 1 : 0, duration: 0.16)
            selection = nil
        }
        updateResults()
    }

    func updateResults() {
        let q = SearchIndex.normalize(chrome.query)
        if q.isEmpty {
            results = []
        } else {
            results = catalogOrder.enumerated()
                .compactMap { i, app in app.search.score(q).map { (app, $0 + usage.boost(app.key), i) } }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
                .map(\.0)
        }
        if isSearching { selection = results.isEmpty ? nil : 0 }
        layoutResults(animated: true)
        refreshSelection()
    }

    private var shownResults: ArraySlice<AppItem> { results.prefix(metrics.capacity) }

    /// A single short row of results sits centred rather than hugging the left.
    private func resultCenter(_ i: Int, count: Int) -> CGPoint {
        var c = metrics.center(for: i)
        if count < metrics.columns { c.x += CGFloat(metrics.columns - count) * metrics.cell.width / 2 }
        return c
    }

    func layoutResults(animated: Bool) {
        let shown = Array(shownResults)
        var live = Set<String>()
        for (i, app) in shown.enumerated() {
            let id = "r:" + app.key
            live.insert(id)
            let target = resultCenter(i, count: shown.count)
            if let t = resultTiles[id] {
                t.configure(content: .app(icon: app.icon), label: app.name, metrics: metrics, tint: app.tint,
                            badge: store.fresh.contains(app.key))
                if animated { Motion.move(t, to: target, response: 0.36, damping: 0.82) } else { Motion.instantly { t.position = target } }
            } else {
                let t = TileLayer(itemID: id)
                t.configure(content: .app(icon: app.icon), label: app.name, metrics: metrics, tint: app.tint,
                            badge: store.fresh.contains(app.key))
                t.setRunning(runningKeys.contains(app.key))
                Motion.instantly { t.position = target }
                resultsLayer.addSublayer(t)
                resultTiles[id] = t
                if animated {
                    t.add(Motion.spring("transform.scale", from: 0.6, to: 1, response: 0.34, damping: 0.72), forKey: "appear")
                    t.add(Motion.basic("opacity", from: 0, to: 1, duration: 0.16), forKey: "fade")
                }
            }
        }
        for (id, t) in resultTiles where !live.contains(id) {
            resultTiles[id] = nil
            if animated {
                CATransaction.begin()
                CATransaction.setCompletionBlock { t.removeFromSuperlayer() }
                Motion.fade(t, to: 0, duration: 0.12)
                CATransaction.commit()
            } else {
                t.removeFromSuperlayer()
            }
        }
        updateEmptyLabel(visible: isSearching && shown.isEmpty)
    }

    private func updateEmptyLabel(visible: Bool) {
        let label: CALayer
        if let existing = resultsLayer.sublayers?.first(where: { $0.name == "empty" }) {
            label = existing
        } else {
            let l = PlainLayer()
            l.name = "empty"
            l.contentsGravity = .resize
            l.opacity = 0
            resultsLayer.addSublayer(l)
            label = l
        }
        Motion.instantly {
            let w: CGFloat = 400
            label.frame = CGRect(x: (width - w) / 2, y: metrics.size.height * 0.4, width: w,
                                 height: LabelRenderer.height(fontSize: 22))
            label.contents = LabelRenderer.image(L10n.noResults, fontSize: 22, width: w)
        }
        Motion.fade(label, to: visible ? 0.65 : 0, duration: 0.15)
    }

    func resultIndex(at p: CGPoint) -> Int? {
        let shown = shownResults
        let size = TileLayer.size(for: metrics)
        for i in shown.indices {
            let c = resultCenter(i, count: shown.count)
            let hit = CGRect(x: c.x - metrics.iconSize * 0.62, y: c.y - size.height / 2,
                             width: metrics.iconSize * 1.24, height: size.height)
            if hit.contains(p) { return i }
        }
        return nil
    }
}
