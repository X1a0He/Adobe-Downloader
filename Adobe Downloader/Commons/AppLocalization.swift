import Foundation

enum AppInterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var localizationIdentifier: String {
        switch self {
        case .system:
            return Bundle.preferredLocalizations(
                from: ["en", "zh-Hans"],
                forPreferences: Locale.preferredLanguages
            ).first ?? "en"
        case .simplifiedChinese, .english:
            return rawValue
        }
    }

    var locale: Locale {
        Locale(identifier: localizationIdentifier)
    }

    var title: String {
        switch self {
        case .system:
            return AppLocalized("跟随系统")
        case .simplifiedChinese:
            return AppLocalized("简体中文")
        case .english:
            return "English"
        }
    }

    static var current: AppInterfaceLanguage {
        let storedValue = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? system.rawValue
        return AppInterfaceLanguage(rawValue: storedValue) ?? .system
    }

    var bundle: Bundle {
        switch localizationIdentifier {
        case "zh-Hans": return Self.chineseBundle
        default: return Self.englishBundle
        }
    }

    private static let chineseBundle = localizedBundle("zh-Hans")
    private static let englishBundle = localizedBundle("en")

    private static func localizedBundle(_ identifier: String) -> Bundle {
        guard let url = Bundle.main.url(forResource: identifier, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            return .main
        }
        return bundle
    }
}

extension StorageData {
    var interfaceLocale: Locale {
        (AppInterfaceLanguage(rawValue: interfaceLanguage) ?? .system).locale
    }
}

// 查词语言由 Bundle 决定；locale 仅控制插值格式。包装函数使用的目录条目需手动保留。
func AppLocalized(_ keyAndValue: String.LocalizationValue) -> String {
    let language = AppInterfaceLanguage.current
    return String(localized: keyAndValue, bundle: language.bundle, locale: language.locale)
}

func AppLocalizedLegacy(
    _ key: String,
    value: String = "",
    comment: StaticString = ""
) -> String {
    AppInterfaceLanguage.current.bundle.localizedString(forKey: key, value: value, table: nil)
}
