import Foundation

/// Coarse groups used to auto-organize apps into folders.
enum AppCategory: String, CaseIterable, Codable {
    case games, productivity, developer, utilities, social, media, creative, business, education, lifestyle

    var folderName: String {
        switch self {
        case .games: L10n.t("Games", "游戏")
        case .productivity: L10n.t("Productivity", "效率")
        case .developer: L10n.t("Developer Tools", "开发工具")
        case .utilities: L10n.t("Utilities", "实用工具")
        case .social: L10n.t("Social", "社交")
        case .media: L10n.t("Entertainment", "影音娱乐")
        case .creative: L10n.t("Creativity", "创意")
        case .business: L10n.t("Business", "商务")
        case .education: L10n.t("Education", "学习")
        case .lifestyle: L10n.t("Lifestyle", "生活")
        }
    }

    static func detect(appURL: URL, info: [String: Any]) -> AppCategory? {
        if let type = info["LSApplicationCategoryType"] as? String, let c = from(uti: type) { return c }
        if let c = fromITunesMetadata(appURL) { return c }
        if isSteamGame(appURL, info: info) { return .games }
        return nil
    }

    private static func from(uti: String) -> AppCategory? {
        let t = uti.lowercased().replacingOccurrences(of: "public.app-category.", with: "")
        if t.hasSuffix("games") || t == "games" { return .games }
        switch t {
        case "productivity": return .productivity
        case "developer-tools": return .developer
        case "utilities": return .utilities
        case "social-networking": return .social
        case "entertainment", "music", "video": return .media
        case "graphics-design", "photography": return .creative
        case "business", "finance": return .business
        case "education", "reference": return .education
        case "lifestyle", "travel", "health-fitness", "medical", "sports", "weather", "news", "food-and-drink", "shopping":
            return .lifestyle
        default: return nil
        }
    }

    /// Wrapped iPhone/iPad apps carry their App Store genre in iTunesMetadata.plist.
    private static func fromITunesMetadata(_ url: URL) -> AppCategory? {
        let file = url.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        guard let meta = NSDictionary(contentsOf: file) as? [String: Any] else { return nil }
        if let id = meta["genreId"] as? Int, id == 6014 { return .games }
        switch (meta["genre"] as? String)?.lowercased() {
        case "games"?: return .games
        case "education"?, "reference"?, "books"?: return .education
        case "productivity"?: return .productivity
        case "utilities"?: return .utilities
        case "social networking"?: return .social
        case "entertainment"?, "music"?, "photo & video"?: return .media
        case "business"?, "finance"?: return .business
        case "graphics & design"?: return .creative
        case nil: return nil
        default: return .lifestyle
        }
    }

    /// Steam writes tiny launcher bundles whose script runs `open steam://run/<id>`.
    private static func isSteamGame(_ url: URL, info: [String: Any]) -> Bool {
        if (info["CFBundleIdentifier"] as? String) == "com.valvesoftware.steam" { return true }
        guard let exe = info["CFBundleExecutable"] as? String, exe.hasSuffix(".sh"),
              let script = try? String(contentsOf: url.appendingPathComponent("Contents/MacOS/\(exe)"), encoding: .utf8)
        else { return false }
        return script.contains("steam://")
    }
}
