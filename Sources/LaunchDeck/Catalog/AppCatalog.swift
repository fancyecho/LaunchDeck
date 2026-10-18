import AppKit

struct AppItem: Identifiable, Equatable {
    enum Group: Int, Comparable {
        case featured, system, user, utility
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String  // bundle path
    let url: URL
    let bundleID: String?
    let name: String
    let icon: CGImage?
    let search: SearchIndex
    let group: Group
    let featuredRank: Int
    let category: AppCategory?
    /// The icon's dominant colour, used for its hover glow and launch bloom.
    let tint: CGColor?

    /// Stable identity used by the saved layout: survives app updates and moves.
    var key: String { bundleID ?? id }

    static func == (a: AppItem, b: AppItem) -> Bool {
        a.id == b.id && a.name == b.name && a.icon === b.icon
    }
}

/// Discovers installed applications and renders their icons. All work happens on a
/// private queue; icons are cached by path + modification date so rescans are cheap.
final class AppCatalog {
    static let iconPixels = 256

    /// Roughly the first page of the classic Launchpad.
    private static let featuredOrder: [String] = [
        "com.apple.Safari", "com.apple.mail", "com.apple.MobileSMS", "com.apple.FaceTime",
        "com.apple.Maps", "com.apple.Photos", "com.apple.iCal", "com.apple.AddressBook",
        "com.apple.reminders", "com.apple.Notes", "com.apple.freeform", "com.apple.TV",
        "com.apple.Music", "com.apple.podcasts", "com.apple.news", "com.apple.iBooksX",
        "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.iWork.Pages",
        "com.apple.AppStore", "com.apple.systempreferences",
    ]

    private struct Candidate {
        let url: URL
        let group: AppItem.Group
    }

    private struct CachedIcon {
        let stamp: Date?
        let image: CGImage?
        let tint: CGColor?
    }

    private let queue = DispatchQueue(label: "launchdeck.catalog", qos: .userInitiated)
    private let lock = NSLock()
    private var iconCache: [String: CachedIcon] = [:]

    func scan(_ completion: @escaping ([AppItem]) -> Void) {
        queue.async {
            let items = self.performScan()
            DispatchQueue.main.async { completion(items) }
        }
    }

    private func performScan() -> [AppItem] {
        let candidates = discover()
        var built = [AppItem?](repeating: nil, count: candidates.count)
        built.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                buffer[i] = self.makeItem(candidates[i])
            }
        }

        var seenIDs = Set<String>()
        var items: [AppItem] = []
        for case let item? in built {
            if let id = item.bundleID {
                guard seenIDs.insert(id).inserted else { continue }
            }
            items.append(item)
        }

        items.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.featuredRank != b.featuredRank { return a.featuredRank < b.featuredRank }
            return a.search.sortKey.localizedCaseInsensitiveCompare(b.search.sortKey) == .orderedAscending
        }
        return items
    }

    private func discover() -> [Candidate] {
        let fm = FileManager.default
        var seenPaths = Set<String>()
        var out: [Candidate] = []

        func walk(_ dir: URL, depth: Int, group: AppItem.Group) {
            // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink carrying the
            // hidden flag, yet Finder and Launchpad both show it.
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ) else { return }
            for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where !url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension == "app" {
                    let resolved = url.resolvingSymlinksInPath().path
                    if seenPaths.insert(resolved).inserted {
                        out.append(Candidate(url: url, group: group))
                    }
                } else if depth > 1, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let sub: AppItem.Group = url.lastPathComponent == "Utilities" ? .utility : group
                    walk(url, depth: depth - 1, group: sub)
                }
            }
        }

        walk(URL(fileURLWithPath: "/System/Applications"), depth: 1, group: .system)
        walk(URL(fileURLWithPath: "/Applications"), depth: 2, group: .user)
        walk(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), depth: 2, group: .user)
        walk(URL(fileURLWithPath: "/System/Applications/Utilities"), depth: 1, group: .utility)
        return out
    }

    private func makeItem(_ c: Candidate) -> AppItem? {
        let url = c.url
        let info = Self.infoPlist(at: url)
        if Self.flag(info["LSBackgroundOnly"]) { return nil }

        let bundleID = info["CFBundleIdentifier"] as? String
        if let bundleID, bundleID == Bundle.main.bundleIdentifier { return nil }

        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }

        var aliases: [String] = []
        for alias in [url.deletingPathExtension().lastPathComponent,
                      info["CFBundleDisplayName"] as? String,
                      info["CFBundleName"] as? String] + Self.chineseNames(at: url) {
            if let alias, !alias.isEmpty, alias != name, !aliases.contains(alias) { aliases.append(alias) }
        }

        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // Resolve symlinks (e.g. Safari) so the icon has no alias badge.
        let art = icon(for: url.resolvingSymlinksInPath().path, stamp: stamp)
        let featuredIndex = bundleID.flatMap { Self.featuredOrder.firstIndex(of: $0) }
        let group: AppItem.Group = featuredIndex != nil ? .featured : c.group

        return AppItem(
            id: url.path,
            url: url,
            bundleID: bundleID,
            name: name,
            icon: art.image,
            search: SearchIndex(name: name, aliases: aliases),
            group: group,
            featuredRank: featuredIndex ?? Int.max,
            category: AppCategory.detect(appURL: url, info: info),
            tint: art.tint
        )
    }

    private func icon(for path: String, stamp: Date?) -> CachedIcon {
        lock.lock()
        let cached = iconCache[path]
        lock.unlock()
        if let cached, cached.stamp == stamp { return cached }

        let image = Self.renderIcon(path: path)
        let entry = CachedIcon(stamp: stamp, image: image, tint: image.flatMap(Self.dominantColor))
        lock.lock()
        iconCache[path] = entry
        lock.unlock()
        return entry
    }

    /// Saturation-weighted average of the icon's opaque pixels, pushed a little
    /// brighter and more vivid so it glows rather than muddies.
    static func dominantColor(_ image: CGImage) -> CGColor? {
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.6 else { continue }
            let R = Double(pixels[i]) / 255 / a, G = Double(pixels[i + 1]) / 255 / a, B = Double(pixels[i + 2]) / 255 / a
            let hi = max(R, G, B), lo = min(R, G, B)
            let saturation = hi > 0 ? (hi - lo) / hi : 0
            let weight = saturation * saturation * hi + 0.03
            r += R * weight; g += G * weight; b += B * weight; total += weight
        }
        guard total > 0 else { return nil }
        let base = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        return NSColor(hue: h, saturation: min(1, s * 1.3 + 0.05), brightness: max(0.72, min(1, v * 1.15)), alpha: 1).cgColor
    }

    private static func renderIcon(path: String) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: path)
        let px = iconPixels
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(
                data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func infoPlist(at url: URL) -> [String: Any] {
        // Wrapped iOS apps keep their real bundle under WrappedBundle/.
        for rel in ["Contents/Info.plist", "WrappedBundle/Info.plist"] {
            if let dict = NSDictionary(contentsOf: url.appendingPathComponent(rel)) as? [String: Any] {
                return dict
            }
        }
        return [:]
    }

    /// Simplified-Chinese bundle names, indexed whatever the system language is, so
    /// pinyin like "wx" finds WeChat (微信) on an English system too.
    private static func chineseNames(at url: URL) -> [String?] {
        let resources = url.appendingPathComponent("Contents/Resources")
        let locales = ["zh-Hans", "zh_CN", "zh-Hans-CN", "zh_Hans"]
        let keys = ["CFBundleDisplayName", "CFBundleName"]

        if let table = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any] {
            for locale in locales {
                if let strings = table[locale] as? [String: Any] {
                    return keys.map { strings[$0] as? String }
                }
            }
        }
        for locale in locales {
            let file = resources.appendingPathComponent("\(locale).lproj/InfoPlist.strings")
            if let strings = NSDictionary(contentsOf: file) as? [String: Any] {
                return keys.map { strings[$0] as? String }
            }
        }
        return []
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s.lowercased() == "yes" || s.lowercased() == "true"
        default: return false
        }
    }
}
