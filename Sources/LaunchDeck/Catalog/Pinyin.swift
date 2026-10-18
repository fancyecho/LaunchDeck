import Foundation

/// Splits a display name into searchable segments: each Han character becomes its
/// pinyin syllable, Latin runs become lowercase words (split on camelCase).
enum Pinyin {
    struct Segment: Equatable {
        let text: String
        let isHan: Bool
        var initial: String { String(text.prefix(1)) }
    }

    /// Polyphonic characters ICU reads wrongly in common app names.
    private static let phrases: [String: [String]] = [
        "音乐": ["yin", "yue"],
        "银行": ["yin", "hang"],
        "钥匙": ["yao", "shi"],
        "重置": ["chong", "zhi"],
        "单词": ["dan", "ci"],
        "背单": ["bei", "dan"],
        "调试": ["tiao", "shi"],
        "长图": ["chang", "tu"],
        "行情": ["hang", "qing"],
    ]

    static func segments(_ string: String) -> [Segment] {
        var out: [Segment] = []
        var word = ""
        let chars = Array(string)

        func flushWord() {
            if !word.isEmpty {
                out.append(Segment(text: word.lowercased(), isHan: false))
                word = ""
            }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isHan(c) {
                flushWord()
                if i + 1 < chars.count, let pair = phrases[String(chars[i...i + 1])] {
                    out += pair.map { Segment(text: $0, isHan: true) }
                    i += 2
                    continue
                }
                if let s = syllable(c) { out.append(Segment(text: s, isHan: true)) }
            } else if c.isLetter || c.isNumber {
                if c.isUppercase, let last = word.last, last.isLowercase { flushWord() }
                word.append(c)
            } else {
                flushWord()
            }
            i += 1
        }
        flushWord()
        return out
    }

    static func containsHan(_ s: String) -> Bool { s.contains(where: isHan) }

    static func isHan(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    private static func syllable(_ c: Character) -> String? {
        let m = NSMutableString(string: String(c))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let s = (m as String).lowercased().trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

/// Precomputed match keys for one app. Matches full names, pinyin, pinyin initials,
/// word prefixes and loose subsequences, e.g. "wx" / "weixin" / "微信" → 微信.
struct SearchIndex: Equatable {
    let keys: [String]
    let tokens: [String]
    let sortKey: String

    init(name: String, aliases: [String]) {
        var keys: [String] = []
        var tokens: [String] = []
        var sortKey = ""

        func addKey(_ k: String) { if !k.isEmpty, !keys.contains(k) { keys.append(k) } }
        func addToken(_ t: String) { if !t.isEmpty, !tokens.contains(t) { tokens.append(t) } }

        for (i, source) in ([name] + aliases).enumerated() {
            let parts = Pinyin.segments(source)
            addKey(Self.normalize(source))
            addKey(parts.map(\.text).joined())
            if parts.count > 1 { addKey(parts.map(\.initial).joined()) }
            if parts.contains(where: \.isHan) {
                addKey(parts.map { $0.isHan ? $0.initial : $0.text }.joined())
            }
            parts.forEach { addToken($0.text) }
            if i == 0 { sortKey = parts.map(\.text).joined(separator: " ") }
        }

        self.keys = keys
        self.tokens = tokens
        self.sortKey = sortKey.isEmpty ? name.lowercased() : sortKey
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Higher is better; nil means no match. `query` must already be normalized.
    func score(_ query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        var best = 0
        for (i, key) in keys.enumerated() {
            let primaryBonus = i == 0 ? 20 : 0
            if key == query {
                best = max(best, 1000 + primaryBonus)
            } else if key.hasPrefix(query) {
                best = max(best, 900 + primaryBonus - min(key.count, 60))
            } else if key.contains(query) {
                best = max(best, 450 - min(key.count, 60))
            }
        }
        if best < 700, tokens.contains(where: { $0.hasPrefix(query) }) {
            best = 700
        }
        if best == 0, query.count >= 2, keys.contains(where: { Self.isSubsequence(query, of: $0) }) {
            best = 150
        }
        return best > 0 ? best : nil
    }

    private static func isSubsequence(_ q: String, of s: String) -> Bool {
        var idx = s.startIndex
        for ch in q {
            guard let found = s[idx...].firstIndex(of: ch) else { return false }
            idx = s.index(after: found)
        }
        return true
    }
}
