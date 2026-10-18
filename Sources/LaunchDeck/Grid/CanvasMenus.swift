import AppKit
import QuartzCore

/// Menu item that runs a closure, so context menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension LauncherCanvas {
    /// Right-click on an app or folder. Returns false when the click hit empty space.
    func showItemMenu(for event: NSEvent) -> Bool {
        let p = point(event)
        let menu = NSMenu()

        if let f = folder {
            guard let i = folderIndex(at: p), i < f.apps.count, let app = apps[f.apps[i]] else { return false }
            addAppItems(to: menu, app: app)
        } else if isSearching {
            guard let i = resultIndex(at: p), i < results.count else { return false }
            addAppItems(to: menu, app: results[i])
        } else if let i = gridIndex(at: p), page < pages.count, i < pages[page].count {
            switch pages[page][i] {
            case .app(let key):
                guard let app = apps[key] else { return false }
                addAppItems(to: menu, app: app)
            case .folder(let f):
                menu.addItem(ClosureMenuItem(L10n.t("Open", "打开")) { [weak self] in self?.openFolder(f) })
                menu.addItem(ClosureMenuItem(L10n.t("Rename", "重命名")) { [weak self] in
                    self?.openFolder(f)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.beginRenaming() }
                })
            }
        } else {
            return false
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }

    private func addAppItems(to menu: NSMenu, app: AppItem) {
        menu.addItem(ClosureMenuItem(L10n.t("Open", "打开")) { [weak self] in self?.launch(app) })
        menu.addItem(ClosureMenuItem(L10n.t("Show in Finder", "在访达中显示")) { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
            self?.dismissHandler?()
        })
        if !store.hidden.contains(app.key) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L10n.t("Hide from LaunchDeck", "从启动台隐藏")) { [weak self] in
                self?.hide(app)
            })
        }
    }

    /// Fades the app out and closes the gap; it stays findable through search.
    func hide(_ app: AppItem) {
        let id = "a:" + app.key
        let tile = tiles[id] ?? folderTiles[id]
        if let tile {
            Motion.fade(tile, to: 0, duration: 0.18)
            Motion.scale(tile, to: 0.6, response: 0.3, damping: 0.9)
        }
        let inOpenFolder = folder?.apps.contains(app.key) == true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.store.hide(app.key)
            if inOpenFolder, let f = self.folder {
                if let updated = self.store.folder(id: f.id) {
                    self.refreshFolderTiles(updated)
                } else {
                    self.closeFolder(animated: true)
                }
            }
            if let tile, self.tiles[id] === tile {
                tile.removeFromSuperlayer()
                self.tiles[id] = nil
            }
            self.commit(self.store.pages)
            if self.isSearching { self.updateResults() }
        }
    }

    func unhideAll() {
        store.unhideAll(apps: catalogOrder)
        commit(store.pages)
    }
}
