import Foundation
import Observation

@Observable
final class LocaleManager: @unchecked Sendable {

    private(set) var language: String
    private var translations: [String: String] = [:]
    private let supportedLanguages = ["en", "es", "de"]
    private let storageKey = "com.simpledisplay.language"

    init() {
        // Priority: saved preference > system language > English
        let saved = UserDefaults.standard.string(forKey: storageKey)
        let system = Locale.preferredLanguages.first?.components(separatedBy: "-").first
        let detected = saved ?? system ?? "en"
        language = ["en", "es", "de"].contains(detected) ? detected : "en"
        loadTranslations()
    }

    func setLanguage(_ lang: String) {
        guard supportedLanguages.contains(lang), lang != language else { return }
        language = lang
        UserDefaults.standard.set(lang, forKey: storageKey)
        loadTranslations()
    }

    func t(_ key: String) -> String {
        translations[key] ?? key
    }

    func t(_ key: String, _ args: any CVarArg...) -> String {
        let template = translations[key] ?? key
        return String(format: template, arguments: args)
    }

    private func loadTranslations() {
        guard let url = Bundle.module.url(forResource: language, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return
        }
        translations = dict.filter { !$0.key.hasPrefix("@") }
    }
}
