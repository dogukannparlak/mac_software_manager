import Foundation
import Observation

/// The languages the guide ships with.
///
/// The raw values are BCP-47 codes so they line up with `Locale`, which makes
/// the first-launch default fall out of the user's system settings.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Shown in the language picker. A language is always named in itself -
    /// "Türkçe", never "Turkish" - so it stays readable to whoever needs it.
    var endonym: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    var flagSymbol: String {
        switch self {
        case .english: return "textformat.abc"
        case .turkish: return "textformat.abc.dottedunderline"
        }
    }

    /// Best match for the system's preferred languages, falling back to English.
    static var systemPreferred: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let code, let match = AppLanguage(rawValue: code) {
                return match
            }
        }
        return .english
    }
}

/// A single piece of copy in every supported language.
///
/// Keeping both variants together means a translation can never silently go
/// missing: adding a language turns into a compiler error at each call site
/// rather than a string that falls back to English at runtime.
struct Localized: Hashable, Sendable {
    let en: String
    let tr: String

    init(_ en: String, _ tr: String) {
        self.en = en
        self.tr = tr
    }

    subscript(_ language: AppLanguage) -> String {
        switch language {
        case .english: return en
        case .turkish: return tr
        }
    }
}

/// Holds the active language and remembers it between launches.
///
/// The choice lives in the app rather than in the system language, so switching
/// takes effect immediately and without a relaunch.
@Observable
final class LocalizationStore {
    private static let defaultsKey = "com.macupdater.guide.language"

    var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let restored = AppLanguage(rawValue: stored) {
            language = restored
        } else {
            language = .systemPreferred
        }
    }

    func callAsFunction(_ value: Localized) -> String {
        value[language]
    }
}
