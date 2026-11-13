import Foundation

/// What DevDeck itself spends on AI, so nobody has to wonder. Every call the app makes to a model is written here:
/// when, for what (a question to the copilot or an automatic analysis), with which model, and how many tokens.
public struct OwnUsageDay: Codable, Hashable, Sendable {
    /// purpose ("copilot" | "automatic") → tokens
    public var purposes: [String: TokenCount] = [:]
    /// model → tokens
    public var models: [String: TokenCount] = [:]

    public init() {}
    public var total: TokenCount { purposes.values.reduce(TokenCount(), +) }
}

public final class OwnUsage: @unchecked Sendable {
    public static let shared = OwnUsage()
    public init() {}

    private let lock = NSLock()
    private var days: [String: OwnUsageDay] = [:]
    private var url: URL?
    private var loaded = false

    /// Where the ledger lives. Call once at start; without it nothing is recorded (tests, demo).
    public func use(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        url = directory.appendingPathComponent("own-usage.json")
        loaded = false
    }

    private func loadIfNeeded() {
        guard !loaded, let url else { return }
        loaded = true
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode([String: OwnUsageDay].self, from: data) { days = stored }
    }

    public func record(purpose: String, model: String, tokens: TokenCount, date: Date = Date()) {
        guard tokens.total > 0 || tokens.messages > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard url != nil else { return }
        loadIfNeeded()
        let key = AgentUsageReport.dayString(date)
        var day = days[key] ?? OwnUsageDay()
        day.purposes[purpose] = (day.purposes[purpose] ?? TokenCount()) + tokens
        day.models[model] = (day.models[model] ?? TokenCount()) + tokens
        days[key] = day
        // Keep a month.
        for old in days.keys.sorted().dropLast(31) { days[old] = nil }
        if let url, let data = try? JSONEncoder().encode(days) { try? data.write(to: url, options: .atomic) }
    }

    /// Totals of the last `lastDays` days (1 = today).
    public func summary(lastDays: Int, now: Date = Date()) -> OwnUsageDay {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        var out = OwnUsageDay()
        for offset in 0..<lastDays {
            guard let day = days[AgentUsageReport.dayString(now.addingTimeInterval(-Double(offset) * 86_400))] else { continue }
            for (key, value) in day.purposes { out.purposes[key] = (out.purposes[key] ?? TokenCount()) + value }
            for (key, value) in day.models { out.models[key] = (out.models[key] ?? TokenCount()) + value }
        }
        return out
    }

    /// Token counts from the `usage` object of Claude Code, Codex or the OpenAI API (they name the fields alike).
    public static func tokens(fromUsage usage: [String: Any]?) -> TokenCount {
        var tokens = TokenCount()
        guard let usage else { return tokens }
        func number(_ key: String) -> UInt64 { UInt64(max(0, (usage[key] as? NSNumber)?.intValue ?? 0)) }
        let cached = number("cache_read_input_tokens") + number("cached_input_tokens")
            + UInt64(max(0, ((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0))
        let input = number("input_tokens")
        // Codex and OpenAI count cached tokens inside the input; Claude reports them apart.
        let inputIncludesCache = usage["cache_read_input_tokens"] == nil
        tokens.input = inputIncludesCache && input > cached ? input - cached : input
        tokens.cacheRead = cached
        tokens.cacheWrite = number("cache_creation_input_tokens")
        tokens.output = number("output_tokens")
        tokens.messages = 1
        return tokens
    }
}
