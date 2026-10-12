import Foundation

/// The language and region the UI tests launch the app in. English (US)
/// unless the run sets `TEST_RUNNER_MURMURLY_UI_LOCALE`, for example to
/// `ru_RU`, `pt_BR` or `zh_CN`: xcodebuild hands it to the test runner without
/// the prefix, so the same tests also check a translated interface.
enum AppLanguage {
    static let locale = Locale(
        identifier: ProcessInfo.processInfo.environment["MURMURLY_UI_LOCALE"] ?? "en_US"
    )

    /// The app is built next to the test runner.
    private static var app: Bundle? {
        Bundle(url: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Murmurly.app"))
    }

    /// The app's own localization the system picks for the locale, region and
    /// script included: `pt_BR` → "pt-BR", `zh_CN` → "zh-Hans", `de_DE` → "de".
    static let localization = Bundle.preferredLocalizations(
        from: app?.localizations ?? ["en"], forPreferences: [locale.identifier(.bcp47)]
    ).first ?? "en"

    static var launchArguments: [String] {
        ["-AppleLanguages", "(\(localization))", "-AppleLocale", locale.identifier]
    }

    /// The app's own text for a catalog key in that language, filled in like
    /// the app fills it, so a check reads the same in any language.
    static func text(_ key: String, _ arguments: any CVarArg...) -> String {
        let format = app
            .flatMap { $0.path(forResource: localization, ofType: "lproj") }
            .flatMap { Bundle(path: $0) }?
            .localizedString(forKey: key, value: key, table: nil) ?? key
        return String(format: format, locale: locale, arguments: arguments)
    }
}
