import Foundation

/// Interface language. Spanish is the source language: every string in the code is written in Spanish
/// and used as the lookup key for the other languages.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case es, en, pt

    public var title: String {
        switch self {
        case .es: return "Español"
        case .en: return "English"
        case .pt: return "Português"
        }
    }

    /// Name the model is told to answer in.
    public var aiName: String {
        switch self {
        case .es: return "español"
        case .en: return "English"
        case .pt: return "português"
        }
    }

    public var locale: Locale {
        switch self {
        case .es: return Locale(identifier: "es")
        case .en: return Locale(identifier: "en")
        case .pt: return Locale(identifier: "pt_BR")
        }
    }

    /// Best match for the Mac's preferred languages.
    public static var system: AppLanguage {
        for code in Locale.preferredLanguages {
            if code.hasPrefix("es") { return .es }
            if code.hasPrefix("pt") { return .pt }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}

public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: AppLanguage = .es

    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    static func table(_ language: AppLanguage) -> [String: String] {
        switch language {
        case .es: return [:]
        case .en: return english
        case .pt: return portuguese
        }
    }

    /// Translation of a Spanish source string; falls back to the Spanish text when there is none.
    public static func translate(_ key: String, language: AppLanguage? = nil) -> String {
        let lang = language ?? self.language
        guard lang != .es else { return key }
        return table(lang)[key] ?? key
    }

    /// Keys that have no translation in `language` (used by tests to keep the tables complete).
    public static func missing(_ keys: [String], language: AppLanguage) -> [String] {
        let table = table(language)
        return keys.filter { table[$0] == nil }
    }
}

/// Localized string. `L("Cerrar %@", name)` — the Spanish text is the key; `%@`, `%d` and `%.1f` are filled in after translating.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = L10n.translate(key)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

extension L10n {
    /// Display strings that live in data tables (not in an `L("…")` call) and are translated where they are shown.
    public static var dataKeys: [String] {
        var keys: [String] = []
        for recipe in Toolkit.recipes { keys += [recipe.title, recipe.detail, recipe.group] }
        keys += Rule.defaults.map(\.name)
        keys += CacheScanner.patterns.map(\.note)
        for definition in CacheScanner.globalDefinitions { keys += [definition.label, definition.note, definition.regenerate] }
        keys += ["Se vuelve a generar con el build", "Se regenera solo en el próximo dev/build"]
        keys += ["crítica", "alta", "normal", "5 h", "7 días", "créditos ilimitados"]
        // Tool names of the copilot and the sort options of the ports table.
        keys += ["Revisó los mayores consumidores", "Inspeccionó procesos", "Revisó los puertos", "Analizó el swap", "Revisó las cachés",
                 "Revisó el uso de agentes", "Consultó el proyecto", "Puerto", "Memoria", "Proyecto"]
        return Array(Set(keys)).sorted()
    }

    /// `%@`, `%d`… in order, to check that a translation keeps the placeholders of its key.
    public static func placeholders(_ format: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:%|@|d|\\.\\d+f)") else { return [] }
        return regex.matches(in: format, range: NSRange(format.startIndex..., in: format)).compactMap {
            Range($0.range, in: format).map { String(format[$0]) }
        }.filter { $0 != "%%" }
    }
}
