import Foundation

enum L10n {
    // SwiftPM's command-line bundle accessor does not search Contents/Resources.
    static let bundle = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("lokrel_lokrel.bundle")) } ?? Bundle.module
    private static let formattingLocale: Locale = {
        var components = Locale.Components(locale: .current)
        components.languageComponents = Locale.Components(identifier: bundle.preferredLocalizations.first ?? "en").languageComponents
        return Locale(components: components)
    }()

    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: formattingLocale, arguments: arguments)
    }
}
