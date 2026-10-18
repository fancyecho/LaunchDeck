import Foundation

enum L10n {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static func t(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

    static let search = t("Search", "搜索")
    static let noResults = t("No Results", "没有结果")
}
