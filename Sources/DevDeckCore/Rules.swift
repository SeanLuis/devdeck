import Foundation

public enum RuleMetric: String, Codable, CaseIterable, Sendable {
    case groupMemoryMB, groupCPU, systemMemoryPercent, swapUsedMB, pressureLevel, diskFreeGB, headlessBrowsers
    case swapGrowthMBPerMin, swapInMBPerSec

    public var title: String {
        switch self {
        case .groupMemoryMB: return L("RAM de un proyecto/origen (MB)")
        case .groupCPU: return L("CPU de un proyecto/origen (%)")
        case .systemMemoryPercent: return L("RAM usada del sistema (%)")
        case .swapUsedMB: return L("Swap usado (MB)")
        case .pressureLevel: return L("Presión de memoria (1/2/4)")
        case .diskFreeGB: return L("Disco libre (GB)")
        case .headlessBrowsers: return L("Chrome headless abiertos")
        case .swapGrowthMBPerMin: return L("Swap creciendo (MB/min)")
        case .swapInMBPerSec: return L("Lectura de swap (MB/s)")
        }
    }

    public var isGroupMetric: Bool { self == .groupMemoryMB || self == .groupCPU }
    public var defaultComparator: RuleComparator { self == .diskFreeGB ? .below : .above }
}

public enum RuleComparator: String, Codable, CaseIterable, Sendable {
    case above, below
    public var symbol: String { self == .above ? ">" : "<" }
}

public enum RuleAction: String, Codable, CaseIterable, Sendable {
    case notify, killGroup, restartServices, askAI

    public var title: String {
        switch self {
        case .notify: return L("Avisar")
        case .killGroup: return L("Avisar y matar")
        case .restartServices: return L("Avisar y reiniciar")
        case .askAI: return L("Avisar y pedir diagnóstico a la IA")
        }
    }
}

public struct Rule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var metric: RuleMetric
    public var comparator: RuleComparator
    public var threshold: Double
    /// nil = every project group (for group metrics)
    public var targetGroupID: String?
    public var sustainSeconds: Double
    public var action: RuleAction
    public var cooldownSeconds: Double

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, metric: RuleMetric, comparator: RuleComparator? = nil,
                threshold: Double, targetGroupID: String? = nil, sustainSeconds: Double = 15, action: RuleAction = .notify,
                cooldownSeconds: Double = 600) {
        self.id = id; self.name = name; self.enabled = enabled; self.metric = metric
        self.comparator = comparator ?? metric.defaultComparator; self.threshold = threshold
        self.targetGroupID = targetGroupID; self.sustainSeconds = sustainSeconds; self.action = action
        self.cooldownSeconds = cooldownSeconds
    }

    public var summary: String {
        let target = metric.isGroupMetric ? (targetGroupID.map { " [\($0.replacingOccurrences(of: "project:", with: ""))]" } ?? " [\(L("cualquier proyecto"))]") : ""
        return L("%@%@ %@ %@ durante %@s → %@", metric.title, target, comparator.symbol, "\(Int(threshold))", "\(Int(sustainSeconds))", action.title)
    }

    public static var defaults: [Rule] {
        [
            Rule(name: "Presión de memoria crítica", metric: .pressureLevel, threshold: 3, sustainSeconds: 10, action: .askAI, cooldownSeconds: 600),
            Rule(name: "RAM del sistema > 90%", metric: .systemMemoryPercent, threshold: 90, sustainSeconds: 30, cooldownSeconds: 900),
            Rule(name: "Swap > 10 GB", metric: .swapUsedMB, threshold: 10_240, sustainSeconds: 60, cooldownSeconds: 1800),
            Rule(name: "Disco casi lleno", metric: .diskFreeGB, threshold: 15, sustainSeconds: 0, cooldownSeconds: 1800),
            Rule(name: "Enjambre de Chrome headless", metric: .headlessBrowsers, threshold: 12, sustainSeconds: 10, cooldownSeconds: 600),
            Rule(name: "Un proyecto usa > 6 GB", metric: .groupMemoryMB, threshold: 6144, sustainSeconds: 30, cooldownSeconds: 1800),
            Rule(name: "Leyendo de swap (lentitud)", metric: .swapInMBPerSec, threshold: 5, sustainSeconds: 30, cooldownSeconds: 900),
            Rule(name: "Swap creciendo rápido", metric: .swapGrowthMBPerMin, threshold: 200, sustainSeconds: 60, action: .askAI, cooldownSeconds: 1800),
        ]
    }
}

public enum AlertSeverity: String, Codable, Sendable { case info, warning, critical }

public struct AlertEvent: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var time: Date
    public var title: String
    public var message: String
    public var severity: AlertSeverity
    public var groupID: String?
    public var actionTaken: String?

    public init(time: Date = Date(), title: String, message: String, severity: AlertSeverity, groupID: String? = nil, actionTaken: String? = nil) {
        self.time = time; self.title = title; self.message = message; self.severity = severity
        self.groupID = groupID; self.actionTaken = actionTaken
    }
}

public struct RuleFiring: Sendable {
    public let rule: Rule
    public let groupID: String?
    public let groupName: String?
    public let value: Double
    public let message: String
    public let severity: AlertSeverity
}

/// Evaluates rules every tick, with "sustained for N seconds" and cooldown semantics.
public final class RuleEngine {
    private struct State { var overSince: Date?; var lastFired: Date? }
    private var states: [String: State] = [:]

    public init() {}

    public func evaluate(rules: [Rule], snapshot: Snapshot, system: SystemSample, swap: SwapReport = .empty, now: Date = Date()) -> [RuleFiring] {
        var firings: [RuleFiring] = []
        for rule in rules where rule.enabled {
            for (groupID, groupName, value) in values(for: rule, snapshot: snapshot, system: system, swap: swap) {
                let key = "\(rule.id)|\(groupID ?? "")"
                var state = states[key] ?? State()
                let breached = rule.comparator == .above ? value > rule.threshold : value < rule.threshold
                if breached {
                    if state.overSince == nil { state.overSince = now }
                    let sustained = now.timeIntervalSince(state.overSince!) >= rule.sustainSeconds
                    let cooled = state.lastFired.map { now.timeIntervalSince($0) >= rule.cooldownSeconds } ?? true
                    if sustained && cooled {
                        state.lastFired = now
                        firings.append(RuleFiring(rule: rule, groupID: groupID, groupName: groupName, value: value,
                                                  message: message(rule, groupName: groupName, value: value),
                                                  severity: severity(rule, value: value)))
                    }
                } else {
                    state.overSince = nil
                }
                states[key] = state
            }
        }
        return firings
    }

    private func values(for rule: Rule, snapshot: Snapshot, system: SystemSample, swap: SwapReport) -> [(String?, String?, Double)] {
        switch rule.metric {
        case .groupMemoryMB, .groupCPU:
            let groups: [ProcessGroup]
            if let target = rule.targetGroupID { groups = snapshot.group(target).map { [$0] } ?? [] }
            else { groups = snapshot.groups.filter { $0.kind == .project } }
            return groups.map { g in
                (g.id, g.name, rule.metric == .groupMemoryMB ? Fmt.mb(g.memoryBytes) : g.cpuPercent)
            }
        case .systemMemoryPercent: return [(nil, nil, system.memPercent)]
        case .swapUsedMB: return [(nil, nil, Fmt.mb(system.swapUsed))]
        case .pressureLevel: return [(nil, nil, Double(system.pressure))]
        case .diskFreeGB: return [(nil, nil, Fmt.gb(system.diskFree))]
        case .headlessBrowsers: return [(Classifier.headlessID, "Chrome headless", Double(snapshot.headlessBrowserCount))]
        case .swapGrowthMBPerMin: return [(nil, nil, swap.growthMBPerMin)]
        case .swapInMBPerSec: return [(nil, nil, swap.swapInRate / 1_048_576)]
        }
    }

    private func message(_ rule: Rule, groupName: String?, value: Double) -> String {
        let who = groupName.map { "\($0): " } ?? ""
        switch rule.metric {
        case .groupMemoryMB: return L("%@%@ GB de RAM (límite %@ GB)", who, String(format: "%.1f", value / 1024), String(format: "%.1f", rule.threshold / 1024))
        case .groupCPU: return L("%@%@%% de CPU (límite %@%%)", who, "\(Int(value))", "\(Int(rule.threshold))")
        case .systemMemoryPercent: return L("RAM del sistema al %@%%", "\(Int(value))")
        case .swapUsedMB: return L("Swap en %@ GB", String(format: "%.1f", value / 1024))
        case .pressureLevel: return value >= 4 ? L("Presión de memoria CRÍTICA") : L("Presión de memoria alta")
        case .diskFreeGB: return L("Quedan %@ GB libres en disco", String(format: "%.1f", value))
        case .headlessBrowsers: return L("%@ Chrome headless abiertos a la vez", "\(Int(value))")
        case .swapGrowthMBPerMin: return L("El swap crece %@ MB por minuto", "\(Int(value))")
        case .swapInMBPerSec: return L("Leyendo %@ MB/s de swap: la Mac se siente lenta", String(format: "%.1f", value))
        }
    }

    private func severity(_ rule: Rule, value: Double) -> AlertSeverity {
        switch rule.metric {
        case .pressureLevel: return value >= 4 ? .critical : .warning
        case .diskFreeGB: return value < 5 ? .critical : .warning
        default: return .warning
        }
    }
}
