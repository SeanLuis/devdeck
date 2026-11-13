import Foundation

/// List price of a model, in US dollars per million tokens.
public struct ModelPrice: Codable, Hashable, Sendable {
    /// Start of the model id this price applies to ("claude-opus-5-5"); the longest match wins.
    public var match: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(match: String, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil) {
        self.match = match; self.input = input; self.output = output
        // Where the provider's table gives no cache price: reads at a tenth of input, writes at 1.25× (the usual ratio).
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite = cacheWrite ?? input * 1.25
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let input = try c.decode(Double.self, forKey: .input)
        self.init(match: try c.decode(String.self, forKey: .match), input: input, output: try c.decode(Double.self, forKey: .output),
                  cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheRead), cacheWrite: try c.decodeIfPresent(Double.self, forKey: .cacheWrite))
    }
}

/// What the tokens would cost at API list prices. An estimate: a subscription is not billed per token.
public struct PriceTable: Sendable {
    public var prices: [ModelPrice]

    public init(prices: [ModelPrice] = PriceTable.defaults) {
        self.prices = prices.sorted { $0.match.count > $1.match.count }
    }

    /// Anthropic's published API prices (November 2026). Other providers are left to `prices.json`:
    /// a wrong number is worse than none.
    public static let defaults: [ModelPrice] = [
        ModelPrice(match: "claude-fable-5-2", input: 8, output: 40, cacheRead: 0.20),
        ModelPrice(match: "claude-mythos-5-2", input: 8, output: 40, cacheRead: 0.20),
        ModelPrice(match: "claude-fable-5", input: 10, output: 50),
        ModelPrice(match: "claude-mythos-5", input: 10, output: 50),
        ModelPrice(match: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.20),
        ModelPrice(match: "claude-opus-5", input: 5, output: 25),
        ModelPrice(match: "claude-opus-4-8", input: 5, output: 25),
        ModelPrice(match: "claude-opus-4-7", input: 5, output: 25),
        ModelPrice(match: "claude-opus-4-6", input: 5, output: 25),
        ModelPrice(match: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.10),
        ModelPrice(match: "claude-sonnet-5", input: 2, output: 10),
        ModelPrice(match: "claude-sonnet-4-6", input: 3, output: 15),
        ModelPrice(match: "claude-haiku-5-5", input: 0.10, output: 0.50),
        ModelPrice(match: "claude-haiku-4-5", input: 1, output: 5),
    ]

    /// Built-in prices plus the user's own (`prices.json` in the data folder: `[{"match": "gpt-6", "input": 1, "output": 8}]`).
    /// A user entry replaces the built-in one with the same `match`.
    public static func load(directory: URL) -> PriceTable {
        var byMatch = Dictionary(defaults.map { ($0.match, $0) }) { a, _ in a }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("prices.json")),
           let custom = try? JSONDecoder().decode([ModelPrice].self, from: data) {
            for price in custom where !price.match.isEmpty { byMatch[price.match.lowercased()] = price }
        }
        return PriceTable(prices: Array(byMatch.values))
    }

    public func price(for model: String) -> ModelPrice? {
        let id = model.lowercased()
        return prices.first { id.hasPrefix($0.match.lowercased()) }
    }

    public func cost(_ tokens: TokenCount, model: String) -> Double? {
        guard let p = price(for: model) else { return nil }
        return (Double(tokens.input) * p.input + Double(tokens.output) * p.output
                + Double(tokens.cacheRead) * p.cacheRead + Double(tokens.cacheWrite) * p.cacheWrite) / 1_000_000
    }
}

/// Dollars for a slice of usage, and how much of it could not be priced.
public struct CostEstimate: Hashable, Sendable {
    public var dollars: Double = 0
    public var pricedTokens: UInt64 = 0
    public var unpricedTokens: UInt64 = 0

    public init() {}
    public var hasPrice: Bool { pricedTokens > 0 }
    /// True when part of the usage has no known price, so the figure is a floor.
    public var partial: Bool { pricedTokens > 0 && unpricedTokens > 0 }

    public var text: String {
        guard hasPrice else { return "—" }
        let value: String
        switch dollars {
        case ..<0.005: value = "<$0.01"
        case ..<100: value = String(format: "$%.2f", dollars)
        default: value = "$" + (Self.whole.string(from: NSNumber(value: dollars.rounded())) ?? String(Int(dollars)))
        }
        return (partial ? "≥ " : "≈ ") + value
    }

    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US")
        return f
    }()
}

extension AgentUsageReport {
    /// Estimated cost of the buckets that pass `include`.
    public func cost(_ table: PriceTable, where include: (UsageKey) -> Bool = { _ in true }) -> CostEstimate {
        var out = CostEstimate()
        for (key, tokens) in buckets where include(key) {
            if let dollars = table.cost(tokens, model: key.model) {
                out.dollars += dollars
                out.pricedTokens += tokens.billable
            } else {
                out.unpricedTokens += tokens.billable
            }
        }
        return out
    }
}
