import Foundation

public enum AutopilotMode: String, Codable, CaseIterable, Sendable {
    case off, suggest, autoSafe

    public var title: String {
        switch self {
        case .off: return L("Apagado")
        case .suggest: return L("Sugerir")
        case .autoSafe: return L("Aplicar lo seguro")
        }
    }

    public var help: String {
        switch self {
        case .off: return L("La IA solo se usa cuando tú lo pides.")
        case .suggest: return L("Ante una alerta crítica, la IA diagnostica y propone acciones; tú decides.")
        case .autoSafe: return L("Ante una alerta crítica, la IA diagnostica y aplica sola las acciones de riesgo bajo (cerrar Chrome headless, borrar cachés regenerables de proyectos parados).")
        }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case auto, low, medium, high
    public var title: String {
        switch self {
        case .auto: return L("Automático")
        case .low: return L("Bajo (rápido)")
        case .medium: return L("Medio")
        case .high: return L("Alto (más preciso)")
        }
    }
}

public struct AIConfig: Codable, Hashable, Sendable {
    /// Which engine answers: a local agent CLI (no key) or the OpenAI API.
    public var provider: AIProvider = .claudeCode
    /// False until the user (or first-run detection) picks a provider.
    public var providerChosen = false
    public var claudeModel: String = "default"
    public var codexModel: String = "default"
    public var model: String = "gpt-6-luna"
    public var baseURL: String = "https://api.openai.com/v1"
    /// Legacy: a .env file with OPENAI_API_KEY. Migrated into the app's own key storage on launch.
    public var envFilePath: String?
    public var autopilot: AutopilotMode = .suggest
    public var reasoningEffort: ReasoningEffort = .auto
    public var language: String = "español"
    /// Send (redacted) command lines to the model. Off = only names, sizes and ports.
    public var shareCommandLines = true
    public var autoDiagnoseOnAlerts = true
    public var autoDiagnoseEveryMinutes: Double = 5
    public var maxActions: Int = 6
    /// Models the key can use (filled by "Verificar").
    public var availableModels: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AIConfig()
        provider = (try? c.decodeIfPresent(AIProvider.self, forKey: .provider)) ?? d.provider
        providerChosen = try c.decodeIfPresent(Bool.self, forKey: .providerChosen) ?? false
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        codexModel = try c.decodeIfPresent(String.self, forKey: .codexModel) ?? d.codexModel
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        envFilePath = try c.decodeIfPresent(String.self, forKey: .envFilePath)
        autopilot = (try? c.decodeIfPresent(AutopilotMode.self, forKey: .autopilot)) ?? d.autopilot
        reasoningEffort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)) ?? d.reasoningEffort
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        shareCommandLines = try c.decodeIfPresent(Bool.self, forKey: .shareCommandLines) ?? d.shareCommandLines
        autoDiagnoseOnAlerts = try c.decodeIfPresent(Bool.self, forKey: .autoDiagnoseOnAlerts) ?? d.autoDiagnoseOnAlerts
        autoDiagnoseEveryMinutes = try c.decodeIfPresent(Double.self, forKey: .autoDiagnoseEveryMinutes) ?? d.autoDiagnoseEveryMinutes
        maxActions = try c.decodeIfPresent(Int.self, forKey: .maxActions) ?? d.maxActions
        availableModels = try c.decodeIfPresent([String].self, forKey: .availableModels) ?? []
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var sampleInterval: Double = 2
    public var historyMinutes: Double = 30
    public var projectRoots: [String] = ProjectDiscovery.defaultRoots
    public var notificationsEnabled = true
    public var ai = AIConfig()
    /// "system" | "light" | "dark"
    public var appearance = "system"
    /// Live status pill at the top of the screen.
    public var islandEnabled = true
    /// When the island is on screen: "always" | "auto" (only while something needs attention) | "off".
    public var islandMode = "always"
    /// Board the island opens on: "system" | "agents" | "accounts" | "copilot".
    public var deckTab = "system"
    /// Global launcher shortcut (Carbon key code + modifiers) and its printable label.
    public var hotKeyCode: Int = 2
    public var hotKeyModifiers: Int = 2304
    public var hotKeyLabel = "⌥⌘D"
    /// Interface language (also the language the copilot answers in).
    public var language: AppLanguage = .system

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        sampleInterval = try c.decodeIfPresent(Double.self, forKey: .sampleInterval) ?? d.sampleInterval
        historyMinutes = try c.decodeIfPresent(Double.self, forKey: .historyMinutes) ?? d.historyMinutes
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots) ?? d.projectRoots
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        ai = try c.decodeIfPresent(AIConfig.self, forKey: .ai) ?? d.ai
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        islandEnabled = try c.decodeIfPresent(Bool.self, forKey: .islandEnabled) ?? d.islandEnabled
        islandMode = try c.decodeIfPresent(String.self, forKey: .islandMode) ?? (islandEnabled ? "always" : "off")
        deckTab = try c.decodeIfPresent(String.self, forKey: .deckTab) ?? d.deckTab
        hotKeyCode = try c.decodeIfPresent(Int.self, forKey: .hotKeyCode) ?? d.hotKeyCode
        hotKeyModifiers = try c.decodeIfPresent(Int.self, forKey: .hotKeyModifiers) ?? d.hotKeyModifiers
        hotKeyLabel = try c.decodeIfPresent(String.self, forKey: .hotKeyLabel) ?? d.hotKeyLabel
        language = (try? c.decodeIfPresent(AppLanguage.self, forKey: .language)) ?? d.language
    }
}

/// Small JSON files in ~/Library/Application Support/DevDeck.
public final class JSONStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public var logsDirectory: URL { directory.appendingPathComponent("logs", isDirectory: true) }

    public func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    public func save<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
