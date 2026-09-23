import Foundation
import SwiftUI

enum AppLanguage: String {
    case zhHant
    case english
}

/// Minimal bilingual system: UI text is written as tr(Chinese, English) pairs at the call site
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "appLanguage"),
           let saved = AppLanguage(rawValue: raw) {
            language = saved
        } else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            language = preferred.hasPrefix("zh") ? .zhHant : .english
        }
    }

    func toggle() {
        language = language == .zhHant ? .english : .zhHant
    }
}

@MainActor
func tr(_ zh: String, _ en: String) -> String {
    L10n.shared.language == .zhHant ? zh : en
}
