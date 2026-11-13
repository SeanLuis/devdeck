import Foundation

/// A ceiling the user sets on what the agents spend: tokens for a project, an agent or everything,
/// or a share of an account's own limit. DevDeck only warns; it never stops an agent on its own.
public struct Budget: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case all, agent, project, account }
    public enum Period: String, Codable, CaseIterable, Sendable { case day, week }

    public var id: UUID
    public var kind: Kind
    /// Agent name, project folder or account e-mail; empty for `.all`.
    public var target: String
    /// Today / the last 7 days. For an account: its 5-hour / 7-day window.
    public var period: Period
    /// Tokens (input + output + cache writes), or a percentage of the account's window for `.account`.
    public var limit: Double
    public var enabled: Bool

    public init(id: UUID = UUID(), kind: Kind, target: String = "", period: Period, limit: Double, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.target = target; self.period = period; self.limit = limit; self.enabled = enabled
    }

    /// Name of the account window this budget watches.
    public var windowName: String { period == .day ? "5 h" : "7 días" }
}

public struct BudgetStatus: Identifiable, Hashable, Sendable {
    public var id: UUID { budget.id }
    public let budget: Budget
    /// Tokens spent, or the account window's percentage.
    public let used: Double
    /// False when the data the budget needs is not there (account without published limits).
    public let measurable: Bool
    /// When the count starts again, if known.
    public let resetsAt: Date?

    public var fraction: Double { budget.limit > 0 ? used / budget.limit : 0 }
}

public struct BudgetFiring: Hashable, Sendable {
    public let status: BudgetStatus
    /// 80 or 100.
    public let level: Int
}

public enum Budgets {
    public static let warnLevels = [100, 80]

    public static func status(_ budget: Budget, usage: AgentUsageReport, accounts: AccountsReport, now: Date = Date()) -> BudgetStatus {
        if budget.kind == .account {
            let window = accounts.accounts.first { $0.email == budget.target }?.windows.first { $0.name == budget.windowName }
            return BudgetStatus(budget: budget, used: window?.percent ?? 0, measurable: window != nil, resetsAt: window?.resetsAt)
        }
        let today = AgentUsageReport.dayString(now)
        var tokens: UInt64 = 0
        for (key, value) in usage.buckets {
            if budget.period == .day, key.day != today { continue }
            switch budget.kind {
            case .agent: if key.agent != budget.target { continue }
            case .project: if key.project != budget.target, !key.project.hasPrefix(budget.target + "/") { continue }
            case .all, .account: break
            }
            tokens += value.billable
        }
        let reset = budget.period == .day ? Calendar.current.startOfDay(for: now).addingTimeInterval(86_400) : nil
        return BudgetStatus(budget: budget, used: Double(tokens), measurable: true, resetsAt: reset)
    }

    /// Marks the period a firing belongs to, so each level is announced once per period.
    static func periodKey(_ status: BudgetStatus, now: Date) -> String {
        if status.budget.kind == .account, let resets = status.resetsAt {
            // Reset times jitter by seconds between reads; the hour is stable.
            return "w\(Int(resets.timeIntervalSince1970 / 3600))"
        }
        return AgentUsageReport.dayString(now)
    }

    /// Budgets that crossed 80 % or 100 % and were not announced yet in this period. `fired` is updated in place
    /// ("<budget id>|<level>" → period key) and is meant to be persisted.
    public static func evaluate(_ budgets: [Budget], usage: AgentUsageReport, accounts: AccountsReport, fired: inout [String: String],
                                now: Date = Date()) -> [BudgetFiring] {
        var out: [BudgetFiring] = []
        let ids = Set(budgets.map { $0.id.uuidString })
        fired = fired.filter { ids.contains(String($0.key.prefix(36))) }
        for budget in budgets where budget.enabled && budget.limit > 0 {
            let status = status(budget, usage: usage, accounts: accounts, now: now)
            guard status.measurable else { continue }
            let period = periodKey(status, now: now)
            let percent = status.fraction * 100
            var announced = false
            for level in warnLevels where percent >= Double(level) {
                let key = "\(budget.id.uuidString)|\(level)"
                if fired[key] != period {
                    fired[key] = period
                    // Crossing 100 % also covers 80 %: one notice, the highest.
                    if !announced { out.append(BudgetFiring(status: status, level: level)); announced = true }
                }
            }
        }
        return out
    }
}
