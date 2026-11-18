import Foundation

/// Brand names follow the app's resolved localization, including system-language fallback.
enum AppBranding {
    static let name = "Memozia"

    static var displayName: String {
        guard let chineseName else { return name }
        return "\(name) · \(chineseName)"
    }

    static var chineseName: String? {
        guard let localization = Bundle.main.preferredLocalizations.first else { return nil }
        let language = Locale.Language(identifier: localization)
        guard language.languageCode?.identifier == "zh" else { return nil }
        return language.script?.identifier == "Hant" ? "聞墨集" : "闻墨集"
    }
}
