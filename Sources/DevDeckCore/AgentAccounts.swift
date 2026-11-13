import Foundation

/// One usage limit of an account ("5 h", "7 días", a per-model quota…).
public struct UsageWindow: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let percent: Double
    public let resetsAt: Date?
    /// False when, at the current pace, the quota runs out before it resets.
    public let willLast: Bool?

    public init(name: String, percent: Double, resetsAt: Date?, willLast: Bool? = nil) {
        self.name = name; self.percent = percent; self.resetsAt = resetsAt; self.willLast = willLast
    }
}

/// A login of a coding agent on this Mac, with whatever the agent says about its limits.
public struct AgentAccount: Identifiable, Hashable, Sendable {
    public var id: String { "\(agent)|\(number.map(String.init) ?? email)" }
    public let agent: String
    /// Slot number in the account switcher, when one manages this account.
    public var number: Int?
    public var email: String
    public var organization: String?
    public var plan: String?
    public var active: Bool
    public var windows: [UsageWindow] = []
    public var loginExpires: Date?
    public var usageFetched: Date?
    /// Free-form note (credits, status reported by the switcher…).
    public var note: String?
    /// Id in DevDeck's own account store, when DevDeck manages this login.
    public var vaultID: String?
    public var alias: String?

    public init(agent: String, number: Int? = nil, email: String, organization: String? = nil, plan: String? = nil, active: Bool) {
        self.agent = agent; self.number = number; self.email = email; self.organization = organization; self.plan = plan; self.active = active
    }
}

public struct AccountsReport: Sendable {
    public var accounts: [AgentAccount] = []
    /// Path of `cswap` (claude-swap) when installed: it knows the real limits and can switch accounts.
    public var switcherPath: String?
    public var loadedAt: Date?
    /// True when the Claude Code accounts come from DevDeck's own store.
    public var native = false
    /// Accounts claude-swap manages that DevDeck could adopt.
    public var adoptable = 0

    public static let empty = AccountsReport()
    public init() {}

    public func accounts(of agent: String) -> [AgentAccount] { accounts.filter { $0.agent == agent } }
}

/// Reads the accounts the agents are logged into. Everything stays on this Mac; tokens are never read out of the files.
public enum AgentAccounts {
    /// Accounts from DevDeck's own store, with the limits last read for each.
    public static func native(vault: AccountVault, usage: [String: AccountUsage]) -> [AgentAccount] {
        let active = vault.activeAccount()?.id
        let tier = claudeProfile(home: vault.home)?.plan
        return vault.accounts().filter { $0.agent == AccountVault.claude }.enumerated().map { index, stored in
            var account = AgentAccount(agent: stored.agent, number: index + 1, email: stored.email, organization: stored.organizationName,
                                       plan: stored.id == active ? tier : nil, active: stored.id == active)
            account.vaultID = stored.id
            account.alias = stored.alias
            if let reading = usage[stored.id] {
                account.windows = reading.usageWindows()
                account.usageFetched = reading.fetchedAt
                account.note = reading.note
            }
            return account
        }
    }

    public static func load(env: [String: String], codexPlan: CodexPlan?, home: String = NSHomeDirectory(),
                            vault: AccountVault? = nil, usage: [String: AccountUsage] = [:]) async -> AccountsReport {
        var report = AccountsReport()
        let profile = claudeProfile(home: home)
        if let vault {
            let own = native(vault: vault, usage: usage)
            if !own.isEmpty {
                report.native = true
                report.accounts = own
                // Logged into something that was never saved: show it too, so it can be added.
                if let profile, !own.contains(where: \.active) { report.accounts.insert(profile, at: 0) }
            }
            report.adoptable = vault.adoptableCount
        }
        if !report.native, let path = LoginEnvironment.which("cswap", env: env) {
            let result = await Shell.run(path, ["list", "--json"], env: env, timeout: 12)
            let managed = parseSwitcher(Data(result.stdout.utf8))
            if !managed.isEmpty {
                report.switcherPath = path
                report.accounts += managed.map { account in
                    var a = account
                    if a.active, a.plan == nil { a.plan = profile?.plan }
                    return a
                }
            }
        }
        if !report.native, report.accounts.isEmpty, let profile { report.accounts.append(profile) }
        let codexLive = codexProfile(home: home, plan: codexPlan)
        let savedCodex = vault?.accounts().filter { $0.agent == AccountVault.codex } ?? []
        if savedCodex.isEmpty {
            if let codexLive { report.accounts.append(codexLive) }
        } else {
            let active = vault?.activeCodexAccount()?.id
            for (index, stored) in savedCodex.enumerated() {
                var account = AgentAccount(agent: AccountVault.codex, number: index + 1, email: stored.email, plan: planLabel(stored.organizationName),
                                           active: stored.id == active)
                account.vaultID = stored.id
                account.alias = stored.alias
                // Codex only reports limits in the sessions of the login in use.
                if account.active, let codexLive { account.windows = codexLive.windows; account.note = codexLive.note; account.plan = codexLive.plan ?? account.plan }
                report.accounts.append(account)
            }
            if active == nil, let codexLive { report.accounts.append(codexLive) }
        }
        report.loadedAt = Date()
        return report
    }

    /// Makes `number` the account Claude Code uses from now on.
    public static func switchClaude(to number: Int, switcherPath: String, env: [String: String]) async -> ShellResult {
        await Shell.run(switcherPath, ["switch", String(number)], env: env, timeout: 30)
    }

    // MARK: claude-swap

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func window(_ name: String, _ value: Any?) -> UsageWindow? {
        guard let obj = value as? [String: Any], let percent = (obj["pct"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(name: name, percent: percent, resetsAt: date(obj["resetsAt"]), willLast: obj["willLastToReset"] as? Bool)
    }

    /// `cswap list --json` → accounts. Tolerates text around the JSON (upgrade notices).
    public static func parseSwitcher(_ data: Data) -> [AgentAccount] {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let root = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let list = root["accounts"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let email = item["email"] as? String else { return nil }
            var account = AgentAccount(agent: "Claude Code", number: (item["number"] as? NSNumber)?.intValue, email: email,
                                       organization: item["organizationName"] as? String, plan: nil,
                                       active: (item["active"] as? Bool) ?? false)
            if let usage = item["usage"] as? [String: Any] {
                if let w = window("5 h", usage["fiveHour"]) { account.windows.append(w) }
                if let w = window("7 días", usage["sevenDay"]) { account.windows.append(w) }
                for scoped in (usage["scoped"] as? [[String: Any]]) ?? [] {
                    if let name = scoped["name"] as? String, let w = window(name, scoped) { account.windows.append(w) }
                }
            }
            account.loginExpires = date(item["loginExpiresAt"])
            account.usageFetched = date(item["usageFetchedAt"])
            if let status = item["usageStatus"] as? String, status != "ok" { account.note = status }
            return account
        }
    }

    // MARK: Local profiles

    /// "default_claude_max_5x" → "Max 5x"
    public static func planLabel(_ tier: String?) -> String? {
        guard let tier = tier?.lowercased(), !tier.isEmpty else { return nil }
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        if tier.contains("max") { return "Max" }
        if tier.contains("team") { return "Team" }
        if tier.contains("enterprise") { return "Enterprise" }
        if tier.contains("pro") { return "Pro" }
        if tier.contains("plus") { return "Plus" }
        if tier.contains("free") { return "Free" }
        return tier.replacingOccurrences(of: "default_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// The account Claude Code is logged into, from `~/.claude.json`.
    public static func claudeProfile(home: String) -> AgentAccount? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any], let email = account["emailAddress"] as? String else { return nil }
        let plan = planLabel(account["userRateLimitTier"] as? String) ?? planLabel(account["organizationType"] as? String)
        return AgentAccount(agent: "Claude Code", email: email, organization: account["organizationName"] as? String, plan: plan, active: true)
    }

    /// Claims of a JWT (no signature check: it is only used to show the user their own e-mail).
    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The ChatGPT account Codex is logged into, from `~/.codex/auth.json`, plus the limits Codex logs in its sessions.
    public static func codexProfile(home: String, plan: CodexPlan?) -> AgentAccount? {
        var email: String?
        var planType = plan?.planType
        if let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.codex/auth.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let tokens = root["tokens"] as? [String: Any], let id = tokens["id_token"] as? String, let claims = jwtClaims(id) {
                email = claims["email"] as? String
                if planType == nil, let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                    planType = auth["chatgpt_plan_type"] as? String
                }
            } else if (root["OPENAI_API_KEY"] as? String)?.isEmpty == false {
                email = "API key"
            }
        }
        guard email != nil || plan != nil else { return nil }
        var account = AgentAccount(agent: "Codex", email: email ?? "—", plan: planLabel(planType), active: true)
        if let percent = plan?.primaryUsedPercent { account.windows.append(UsageWindow(name: "5 h", percent: percent, resetsAt: plan?.primaryResets)) }
        if let percent = plan?.secondaryUsedPercent { account.windows.append(UsageWindow(name: "7 días", percent: percent, resetsAt: plan?.secondaryResets)) }
        account.note = plan?.credits
        return account
    }
}

/// "This account is about to run out and that one has room": the suggestion DevDeck makes. It never switches on its own.
public struct AccountSwitchSuggestion: Hashable, Sendable {
    public let from: AgentAccount
    public let to: AgentAccount
    /// The window that is running out, and how full it is.
    public let window: UsageWindow

    /// Changes when the window resets, so each cycle is announced once.
    public var key: String { "\(from.id)|\(window.name)|\(Int((window.resetsAt?.timeIntervalSince1970 ?? 0) / 3600))" }
}

extension AccountsReport {
    /// The busiest window of an account (per-model quotas included).
    static func peak(_ account: AgentAccount) -> UsageWindow? { account.windows.max { $0.percent < $1.percent } }

    /// When the Claude Code account in use passes `threshold` and a saved one has clearly more room, the one with the most room.
    public func switchSuggestion(threshold: Double, now: Date = Date()) -> AccountSwitchSuggestion? {
        let claude = accounts(of: "Claude Code").filter { $0.vaultID != nil }
        guard let active = claude.first(where: \.active), let hot = Self.peak(active), hot.percent >= threshold else { return nil }
        let fresh: TimeInterval = 1800
        let candidates = claude.filter { candidate in
            // Only accounts whose limits were read recently: an old reading is not a reason to move.
            guard !candidate.active, !candidate.windows.isEmpty, candidate.note == nil,
                  let read = candidate.usageFetched, now.timeIntervalSince(read) < fresh, let peak = Self.peak(candidate) else { return false }
            return peak.percent <= min(70, threshold - 20)
        }
        guard let best = candidates.min(by: { (Self.peak($0)?.percent ?? 100) < (Self.peak($1)?.percent ?? 100) }) else { return nil }
        return AccountSwitchSuggestion(from: active, to: best, window: hot)
    }
}

