import Foundation

struct Folder: Codable, Equatable {
    var id: String
    var name: String
    var apps: [String]  // AppItem.key
}

enum LayoutItem: Codable, Equatable {
    case app(String)
    case folder(Folder)

    var id: String {
        switch self {
        case .app(let key): "a:" + key
        case .folder(let f): "f:" + f.id
        }
    }

    var appKeys: [String] {
        switch self {
        case .app(let key): [key]
        case .folder(let f): f.apps
        }
    }

    var folder: Folder? {
        if case .folder(let f) = self { return f }
        return nil
    }
}

/// The user's arrangement: pages of apps and folders, saved to
/// ~/Library/Application Support/LaunchDeck/layout.json.
final class LayoutStore {
    private(set) var pages: [[LayoutItem]] = []
    var capacity = 35 {
        didSet { if capacity != oldValue { pages = Self.normalized(pages, capacity: capacity) } }
    }

    /// Apps kept off the grid (still searchable).
    private(set) var hidden = Set<String>()
    /// Apps installed since the layout was made and not yet opened; they get a
    /// blue dot before their name, as in Launchpad.
    private(set) var fresh = Set<String>()

    private struct Snapshot: Codable {
        var version: Int
        var pages: [[LayoutItem]]
        var hidden: [String]?
        var fresh: [String]?
    }

    private let fileURL: URL = {
        if let override = ProcessInfo.processInfo.environment["LAUNCHDECK_LAYOUT_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchDeck/layout.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            pages = snapshot.pages
            hidden = Set(snapshot.hidden ?? [])
            fresh = Set(snapshot.fresh ?? [])
        }
    }

    var hasSavedLayout: Bool { pages.contains { !$0.isEmpty } }

    func setPages(_ newPages: [[LayoutItem]]) {
        pages = Self.normalized(newPages, capacity: capacity)
        save()
    }

    func updateFolder(id: String, _ change: (inout Folder) -> Void) {
        for p in pages.indices {
            for i in pages[p].indices {
                if case .folder(var f) = pages[p][i], f.id == id {
                    change(&f)
                    pages[p][i] = .folder(f)
                    save()
                    return
                }
            }
        }
    }

    func folder(id: String) -> Folder? {
        for page in pages {
            for item in page { if let f = item.folder, f.id == id { return f } }
        }
        return nil
    }

    /// Drops uninstalled apps, appends newly installed ones, and builds the default
    /// arrangement the first time. Returns true when anything changed.
    @discardableResult
    func sync(with apps: [AppItem]) -> Bool {
        guard hasSavedLayout else {
            pages = Self.defaultLayout(apps.filter { !hidden.contains($0.key) }, capacity: capacity)
            save()
            return true
        }

        let installed = Set(apps.map(\.key)).subtracting(hidden)
        var seen = Set<String>()
        var next: [[LayoutItem]] = pages.map { page in
            page.compactMap { item -> LayoutItem? in
                switch item {
                case .app(let key):
                    return installed.contains(key) && seen.insert(key).inserted ? item : nil
                case .folder(var f):
                    f.apps = f.apps.filter { installed.contains($0) && seen.insert($0).inserted }
                    if f.apps.isEmpty { return nil }
                    return f.apps.count == 1 ? .app(f.apps[0]) : .folder(f)
                }
            }
        }

        let addedKeys = apps.map(\.key).filter { installed.contains($0) && !seen.contains($0) }
        if !addedKeys.isEmpty {
            if next.isEmpty { next = [[]] }
            next[next.count - 1].append(contentsOf: addedKeys.map { .app($0) })
        }
        var nextFresh = fresh.union(addedKeys)
        nextFresh.formIntersection(installed)
        next = Self.normalized(next, capacity: capacity)
        guard next != pages || nextFresh != fresh else { return false }
        pages = next
        fresh = nextFresh
        save()
        return true
    }

    func resetToDefault(apps: [AppItem]) {
        pages = Self.defaultLayout(apps.filter { !hidden.contains($0.key) }, capacity: capacity)
        save()
    }

    /// Takes an app off the grid (out of any folder too); search still finds it.
    func hide(_ key: String) {
        hidden.insert(key)
        fresh.remove(key)
        pages = Self.normalized(pages.map { items in
            items.compactMap { item -> LayoutItem? in
                switch item {
                case .app(let k): return k == key ? nil : item
                case .folder(var f):
                    f.apps.removeAll { $0 == key }
                    if f.apps.isEmpty { return nil }
                    return f.apps.count == 1 ? .app(f.apps[0]) : .folder(f)
                }
            }
        }, capacity: capacity)
        save()
    }

    /// Puts every hidden app back, at the end of the last page.
    func unhideAll(apps: [AppItem]) {
        let restore = apps.map(\.key).filter { hidden.contains($0) }
        hidden.removeAll()
        if !restore.isEmpty {
            var next = pages
            if next.isEmpty { next = [[]] }
            next[next.count - 1].append(contentsOf: restore.map { .app($0) })
            pages = Self.normalized(next, capacity: capacity)
        }
        save()
    }

    func markOpened(_ key: String) {
        guard fresh.remove(key) != nil else { return }
        save()
    }

    private func save() {
        let snapshot = Snapshot(version: 1, pages: pages, hidden: hidden.sorted(), fresh: fresh.sorted())
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("LaunchDeck: could not save layout: \(error)")
        }
    }

    // MARK: - Pure helpers

    /// Pushes overflow onto the following page (like Launchpad) and drops empty pages.
    static func normalized(_ input: [[LayoutItem]], capacity: Int) -> [[LayoutItem]] {
        let cap = max(capacity, 1)
        var pages = input
        var i = 0
        while i < pages.count {
            if pages[i].count > cap {
                let overflow = Array(pages[i][cap...])
                pages[i].removeSubrange(cap...)
                if i + 1 < pages.count {
                    pages[i + 1].insert(contentsOf: overflow, at: 0)
                } else {
                    pages.append(overflow)
                }
            }
            i += 1
        }
        pages.removeAll { $0.isEmpty }
        return pages.isEmpty ? [[]] : pages
    }

    /// Lesser-used system apps that Launchpad tucked into its "Other" folder.
    private static let otherFolderIDs: Set<String> = [
        "com.apple.Automator", "com.apple.Chess", "com.apple.Dictionary", "com.apple.FontBook",
        "com.apple.Image_Capture", "com.apple.exposelauncher", "com.apple.Stickies",
        "com.apple.backup.launcher", "com.apple.helpviewer", "com.apple.siri.launcher",
        "com.apple.campo", "com.apple.apps.launcher", "com.apple.stocks",
    ]

    /// Apple apps first with an "Other" folder, then third-party apps on fresh pages
    /// with same-category apps gathered into folders.
    static func defaultLayout(_ apps: [AppItem], capacity: Int) -> [[LayoutItem]] {
        var systemItems: [LayoutItem] = []
        var otherApps: [String] = []
        var thirdParty: [AppItem] = []

        for app in apps {
            switch app.group {
            case .featured:
                systemItems.append(.app(app.key))
            case .system:
                if let id = app.bundleID, otherFolderIDs.contains(id) {
                    otherApps.append(app.key)
                } else {
                    systemItems.append(.app(app.key))
                }
            case .utility:
                otherApps.append(app.key)
            case .user:
                thirdParty.append(app)
            }
        }
        // Keep the Other folder on the first page: spill the last system apps into it.
        let featuredCount = apps.filter { $0.group == .featured }.count
        while !otherApps.isEmpty, systemItems.count + 1 > capacity, systemItems.count > featuredCount,
              case .app(let key) = systemItems.removeLast() {
            otherApps.insert(key, at: 0)
        }
        if !otherApps.isEmpty {
            systemItems.append(.folder(Folder(id: UUID().uuidString, name: L10n.t("Other", "其他"), apps: otherApps)))
        }

        var buckets: [AppCategory: [AppItem]] = [:]
        var loose: [AppItem] = []
        for app in thirdParty {
            if let c = app.category { buckets[c, default: []].append(app) } else { loose.append(app) }
        }
        var folders: [LayoutItem] = []
        for category in AppCategory.allCases {
            guard let members = buckets[category] else { continue }
            if members.count >= 2 {
                folders.append(.folder(Folder(id: UUID().uuidString, name: category.folderName, apps: members.map(\.key))))
            } else {
                loose.append(contentsOf: members)
            }
        }
        loose.sort { $0.search.sortKey.localizedCaseInsensitiveCompare($1.search.sortKey) == .orderedAscending }

        let systemPages = normalized([systemItems], capacity: capacity).filter { !$0.isEmpty }
        let userPages = normalized([folders + loose.map { .app($0.key) }], capacity: capacity).filter { !$0.isEmpty }
        let all = systemPages + userPages
        return all.isEmpty ? [[]] : all
    }

    /// Name for a folder made by dropping one app onto another.
    static func suggestedFolderName(_ a: AppItem?, _ b: AppItem?) -> String {
        if let ca = a?.category, ca == b?.category { return ca.folderName }
        if let c = a?.category ?? b?.category { return c.folderName }
        return L10n.t("Folder", "文件夹")
    }
}
