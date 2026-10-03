import Foundation

enum HelperLocalization {
    // The helper has no AppLanguage store. Resolve its user-visible copy from
    // the process's preferred languages without reading the app's preferences.
    static func localized(
        _ key: String,
        preferredLanguages: [String] = Locale.preferredLanguages,
        catalogURL: URL? = resourceCatalogURL
    ) -> String {
        guard let catalogURL,
              let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = catalog["strings"] as? [String: Any] else { return key }
        let preferred = preferredLanguages.first?.lowercased() ?? "en"
        let language = preferred == "zh" || preferred.hasPrefix("zh-") || preferred.hasPrefix("zh_")
            ? "zh-Hans" : "en"
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let localization = localizations?[language] as? [String: Any]
        let unit = localization?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String ?? key
    }

    static var resourceCatalogURL: URL? {
        let moduleBundle = Bundle(for: BundleAnchor.self)
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                          moduleBundle.bundleURL.deletingLastPathComponent(),
                          Bundle.main.executableURL?.deletingLastPathComponent()]
        for candidate in candidates {
            if let directory = candidate?.appendingPathComponent("AskKey_AskKeyHelper.bundle"),
               let bundle = Bundle(url: directory),
               let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings") {
                return url
            }
        }
        return nil
    }

    private final class BundleAnchor {}
}
