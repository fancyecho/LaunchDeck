import Foundation

/// How often and how recently each app was opened from LaunchDeck, used to put
/// the apps you actually use first among equally good search matches.
final class UsageStore {
    private struct Entry: Codable {
        var count: Int
        var last: Date
    }

    private var entries: [String: Entry] = [:]
    private let fileURL: URL = {
        if let layout = ProcessInfo.processInfo.environment["LAUNCHDECK_LAYOUT_FILE"] {
            return URL(fileURLWithPath: layout).deletingLastPathComponent().appendingPathComponent("usage.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LaunchDeck/usage.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    func recordLaunch(_ key: String) {
        var e = entries[key] ?? Entry(count: 0, last: .distantPast)
        e.count += 1
        e.last = Date()
        entries[key] = e
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }

    /// Small score bonus: frequent use counts for more, recent use fades over a week.
    func boost(_ key: String) -> Int {
        guard let e = entries[key] else { return 0 }
        let frequency = min(Double(e.count), 30) * 2
        let days = Date().timeIntervalSince(e.last) / 86_400
        let recency = max(0, 20 - days * 3)
        return Int(frequency + recency)
    }
}
