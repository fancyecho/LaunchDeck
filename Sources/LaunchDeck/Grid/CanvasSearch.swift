import AppKit
import QuartzCore

extension LauncherCanvas {
    /// The committed query plus whatever the input method is still composing, so
    /// "wx" finds WeChat before a candidate is even picked.
    var searchText: String { chrome.query + chrome.markedText }

    func setQuery(_ q: String) {
        guard q != chrome.query else { return }
        updateSearch { chrome.query = q }
    }

    /// Input-method composition in progress (shown underlined in the bar).
    func setComposing(_ text: String) {
        guard text != chrome.markedText else { return }
        updateSearch { chrome.markedText = text }
    }

    private func updateSearch(_ change: () -> Void) {
        let wasSearching = isSearching
        change()
        if isSearching != wasSearching {
            Motion.fade(gridContainer, to: isSearching ? 0 : 1, duration: isSearching ? 0.16 : 0.22)
            Motion.fade(resultsLayer, to: isSearching ? 1 : 0, duration: 0.16)
            selection = nil
        }
        updateResults()
    }

    /// Typed or committed text goes into the search field from wherever the user
    /// was: no need to click the bar first.
    func typeIntoSearch(_ text: String) {
        let text = text.components(separatedBy: .newlines).joined(separator: " ")
        if chrome.query.isEmpty, text.trimmingCharacters(in: .whitespaces).isEmpty { return }
        prepareForTyping()
        setQuery(chrome.query + text)
    }

    private func prepareForTyping() {
        if folder != nil { closeFolder(animated: true) }
        exitEditMode()
        chrome.isFocused = true
    }

    func focusSearch() {
        exitEditMode()
        selection = nil
        refreshSelection()
        chrome.isFocused = true
    }

    func unfocusSearch() {
        if hasMarkedText() { inputContext?.discardMarkedText() }
        setComposing("")
        chrome.isFocused = false
    }

    /// Back to an idle, collapsed bar with nothing typed.
    func resetSearch() {
        unfocusSearch()
        if chrome.isHovered { NSCursor.arrow.set() }
        chrome.isHovered = false
        setQuery("")
    }

    // MARK: - Search bar geometry

    /// Where the glass bar is drawn right now, in canvas coordinates (y down). The
    /// SwiftUI host is passive, so the canvas hit-tests it.
    var searchBarRect: CGRect {
        let w = SearchBar.width(expanded: chrome.isExpanded, hasText: chrome.hasText)
        return CGRect(x: (width - w) / 2, y: metrics.searchBarY - SearchBar.height / 2, width: w, height: SearchBar.height)
    }

    /// A little more generous than the glass itself, so the collapsed lens is easy to hit.
    func searchBarContains(_ p: CGPoint) -> Bool {
        guard isShown, folder == nil, drag == nil else { return false }
        return searchBarRect.insetBy(dx: -10, dy: -8).contains(p)
    }

    func updateSearchHover(at p: CGPoint) {
        let hovering = searchBarContains(p)
        guard hovering != chrome.isHovered else { return }
        chrome.isHovered = hovering
        (hovering ? NSCursor.iBeam : NSCursor.arrow).set()
        refreshLightMode()
    }

    func updateResults() {
        let q = SearchIndex.normalize(searchText)
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

// MARK: - Input method

/// The canvas is the text input client for the search bar. Keys are routed here
/// from the key monitor (see handleKey), so input methods compose as they would in
/// a text field: pinyin shows underlined in the bar while candidates are picked.
extension LauncherCanvas: NSTextInputClient {
    private static func plainText(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        setComposing("")
        typeIntoSearch(Self.plainText(string))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.plainText(string)
        if !text.isEmpty { prepareForTyping() }
        setComposing(text)
    }

    func unmarkText() {
        let text = chrome.markedText
        setComposing("")
        typeIntoSearch(text)
    }

    func selectedRange() -> NSRange {
        NSRange(location: (searchText as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: (chrome.query as NSString).length, length: (chrome.markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !chrome.markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// The candidate window opens just under the text in the search bar.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let bar = searchBarRect
        let typed = (chrome.query as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        let x = min(bar.minX + 36 + typed, bar.maxX - 24)
        let caret = CGRect(x: x, y: bar.minY + 7, width: 1, height: 20)
        return window.convertToScreen(convert(caret, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Editing keys are handled in handleKey before the input method sees them;
    /// anything it hands back is ignored rather than beeping.
    override func doCommand(by selector: Selector) {}
}
