import Foundation

/// 由 iOS 按系统首选语言选择应用资源；不单独保存语言设置。
enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg..., bundle: Bundle = .main) -> String {
        String(format: string(key, bundle: bundle), locale: Locale.current, arguments: arguments)
    }
}
