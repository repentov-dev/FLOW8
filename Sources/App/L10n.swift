import Foundation

/// Localises strings that SwiftUI cannot resolve by itself (AppKit menus and
/// window titles). The language is the one picked in Settings, so these match
/// the rest of the interface instead of following the system language.
enum L10n {
    static var code: String {
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        if stored != "system" { return stored }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        return String(preferred.prefix(2))
    }

    static var bundle: Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), arguments: arguments)
    }
}
