import Charts
import DevDeckCore
import SwiftUI

/// The boards the island opens into.
enum DeckTab: String, CaseIterable, Identifiable {
    case system, agents, accounts, copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("Sistema")
        case .agents: return L("Agentes")
        case .accounts: return L("Cuentas")
        case .copilot: return L("Copiloto")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gauge.with.dots.needle.50percent"
        case .agents: return "cpu"
        case .accounts: return "person.2"
        case .copilot: return "sparkles"
        }
    }
}

/// Tabs plus the selected board. Lives inside the island; everything here works without the app taking focus.
struct DeckView: View {
    @Environment(AppModel.self) private var model
    let notch: Bool

    var body: some View {
        let tab = DeckTab(rawValue: model.deckTab) ?? .system
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(DeckTab.allCases) { item in
                    Button {
                        model.deckTab = item.rawValue
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.symbol).font(.system(size: 10))
                            Text(item.title).font(.system(size: 12, weight: item == tab ? .semibold : .regular))
                            if item == .copilot, !model.pendingApprovals.isEmpty {
                                Text("\(model.pendingApprovals.count)").font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.warning.opacity(0.25), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.ink(item == tab ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .opacity(item == tab ? 1 : 0.65)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Menu {
                    Button(L("Abrir siempre en “%@”", tab.title)) {
                        model.settings.deckTab = tab.rawValue
                        model.saveSettings()
                    }
                    Divider()
                    Button(model.settings.islandMode == "auto" ? L("Mostrar la isla siempre") : L("Mostrar la isla solo si pasa algo")) {
                        model.settings.islandMode = model.settings.islandMode == "auto" ? "always" : "auto"
                        model.saveSettings()
                        model.deckOpen = false
                        IslandController.shared.update(model: model)
                    }
                    Button(L("Apagar la isla")) {
                        model.settings.islandMode = "off"
                        model.saveSettings()
                        model.deckOpen = false
                        IslandController.shared.update(model: model)
                    }
                    Divider()
                    Button(L("Abrir DevDeck")) { close(); Notifier.shared.onOpen?(.overview) }
                    Button(L("Ajustes")) { close(); Notifier.shared.onOpen?(.settings) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(0.7)
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(0.6)
                .help(L("Cerrar"))
            }
            ScrollView {
                Group {
                    switch tab {
                    case .system: SystemBoard()
                    case .agents: AgentsBoard()
                    case .accounts: AccountsBoard()
                    case .copilot: CopilotBoard()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 470)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, notch ? 6 : 2)
        .padding(.bottom, 14)
    }

    private func close() {
        model.deckOpen = false
        IslandController.shared.update(model: model)
    }
}

// MARK: - System

/// How the machine is doing: RAM, CPU and swap over the last minutes, and who uses the memory.
struct SystemBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.system
        let history = Array(model.systemHistory.suffix(180))
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MetricTile(title: "RAM", value: "\(Int(s.memPercent))%", detail: L("%@ de %@", Fmt.bytes(s.memUsed), Fmt.bytes(s.memTotal)),
                           points: history.map { ($0.time, $0.memPercent) }, range: 0...100, tint: Theme.level(s.memPercent / 100))
                MetricTile(title: "CPU", value: "\(Int(s.cpuPercent))%", detail: L("%@ núcleos", "\(ProcessInfo.processInfo.activeProcessorCount)"),
                           points: history.map { ($0.time, $0.cpuPercent) }, range: 0...100, tint: Theme.tint)
                MetricTile(title: "Swap", value: Fmt.bytes(s.swapUsed), detail: swapState,
                           points: history.map { ($0.time, Fmt.gb($0.swapUsed)) }, range: nil, tint: Theme.tint)
            }
            DeckSection(L("Qué consume más")) {
                let total = Double(max(s.memTotal, 1))
                ForEach(model.snapshot.groups.prefix(5)) { group in
                    HStack(spacing: 8) {
                        Image(systemName: group.kind.symbol).font(.system(size: 10)).frame(width: 16).opacity(0.7)
                        Text(group.name).font(.system(size: 12)).lineLimit(1).frame(width: 150, alignment: .leading)
                        UsageBar(fraction: Double(group.memoryBytes) / total, tint: Theme.tint)
                        Text(Fmt.bytes(group.memoryBytes)).font(.system(size: 11).monospacedDigit()).opacity(0.7).frame(width: 66, alignment: .trailing)
                        Text(Fmt.percent(group.cpuPercent)).font(.system(size: 11).monospacedDigit()).opacity(0.5).frame(width: 40, alignment: .trailing)
                    }
                }
            }
            HStack(spacing: 8) {
                Button(L("Abrir DevDeck")) { open(.overview) }.buttonStyle(.bordered)
                Button(L("Memoria y swap")) { open(.memory) }.buttonStyle(.bordered)
                Spacer()
                Button(L("Preguntar al copiloto")) { model.deckOpen = false; PaletteController.shared.show() }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    private var swapState: String {
        let r = model.swapReport
        if r.thrashing { return "thrashing" }
        if r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 { return L("activo") }
        return model.system.swapUsed > 1 << 30 ? L("dormido") : L("tranquilo")
    }

    private func open(_ section: SidebarSection) {
        model.deckOpen = false
        IslandController.shared.update(model: model)
        Notifier.shared.onOpen?(section)
    }
}

/// A number with its recent history drawn under it.
struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let points: [(Date, Double)]
    let range: ClosedRange<Double>?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).opacity(0.5)
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).opacity(0.5).lineLimit(1)
            chart.frame(height: 38)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 10)
    }

    @ViewBuilder
    private var chart: some View {
        let top = max(points.map(\.1).max() ?? 1, 0.1)
        let domain = range ?? 0...(top * 1.25)
        Chart(Array(points.enumerated()), id: \.offset) { _, point in
            AreaMark(x: .value("t", point.0), y: .value("v", point.1))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", point.0), y: .value("v", point.1))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
    }
}

/// Small titled block inside a board.
struct DeckSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.4).opacity(0.45)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 10)
    }
}

// MARK: - Agents

/// What the coding agents are doing and spending: tokens per hour, and every open session.
struct AgentsBoard: View {
    @Environment(AppModel.self) private var model

    struct Bar: Identifiable {
        let id: String
        let hour: Date
        let agent: String
        let millions: Double
    }

    var body: some View {
        let report = model.agentUsage
        let work = model.agentWork()
        let today = AgentUsageReport.dayString(Date())
        VStack(alignment: .leading, spacing: 12) {
            DeckSection(L("Millones de tokens por hora · últimas 12 h")) {
                let bars = self.bars(report)
                if bars.isEmpty {
                    Text(L("Sin uso en las últimas horas")).font(.system(size: 11)).opacity(0.5).frame(height: 70)
                } else {
                    Chart(bars) { bar in
                        BarMark(x: .value(L("Hora"), bar.hour, unit: .hour), y: .value("M tokens", bar.millions))
                            .foregroundStyle(by: .value(L("Agente"), bar.agent))
                            .cornerRadius(1.5)
                    }
                    .chartForegroundStyleScale(range: ChartPalette.colors)
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { AxisValueLabel(format: .dateTime.hour()) } }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine().foregroundStyle(Theme.ink(0.08)); AxisValueLabel() } }
                    .chartLegend(position: .bottom, spacing: 6)
                    .frame(height: 104)
                }
            }
            HStack(spacing: 8) {
                ForEach(report.agents.prefix(4), id: \.self) { agent in
                    let day = report.total(agent: agent, day: today)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent).font(.system(size: 10, weight: .medium)).opacity(0.5).lineLimit(1)
                        Text(day.messages > 0 ? compact(day.billable) : "—").font(.system(size: 14, weight: .semibold).monospacedDigit())
                        Text(L("hoy · %@ en 5 h", compact(report.recent(agent: agent, hours: 5).billable))).font(.system(size: 10)).opacity(0.5).lineLimit(1)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glass(cornerRadius: 10)
                }
            }
            DeckSection(L("Trabajando ahora")) {
                ForEach(work.live.sorted { ($0.state == .working ? 0 : 1, -Double($0.load?.memoryBytes ?? 0)) < ($1.state == .working ? 0 : 1, -Double($1.load?.memoryBytes ?? 0)) }.prefix(6)) { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.state == .working ? Theme.success : Theme.ink(0.3)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.folderName.isEmpty ? (row.name ?? L("Aplicación y servicios")) : row.folderName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text([row.agent, row.model].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).opacity(0.5).lineLimit(1)
                        }
                        if !row.activeSubagents.isEmpty {
                            Pill(text: plural(row.activeSubagents.count, "%d subagente activo", "%d subagentes activos"), color: Theme.success)
                        }
                        Spacer(minLength: 6)
                        Text(row.load.map { Fmt.bytes($0.memoryBytes) } ?? "—").font(.system(size: 11).monospacedDigit()).opacity(0.7).frame(width: 66, alignment: .trailing)
                        Text(row.tokens.map { compact($0.billable) } ?? "—").font(.system(size: 11).monospacedDigit()).opacity(0.5).frame(width: 46, alignment: .trailing)
                    }
                }
                if work.live.isEmpty { Text(L("Ningún agente abierto ahora mismo.")).font(.system(size: 11)).opacity(0.5) }
            }
            HStack {
                Button(L("Ver todo en Agentes de IA")) {
                    model.deckOpen = false
                    IslandController.shared.update(model: model)
                    Notifier.shared.onOpen?(.agents)
                }
                .buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }
        }
    }

    private func bars(_ report: AgentUsageReport) -> [Bar] {
        let now = Int(Date().timeIntervalSince1970 / 3600)
        var out: [Bar] = []
        for agent in report.agents {
            for hour in (now - 11)...now {
                let tokens = report.hourly[agent]?[hour]?.billable ?? 0
                guard tokens > 0 else { continue }
                out.append(Bar(id: "\(agent)-\(hour)", hour: Date(timeIntervalSince1970: Double(hour) * 3600), agent: agent, millions: Double(tokens) / 1_000_000))
            }
        }
        return out
    }
}

// MARK: - Accounts

/// Every login with its limits, and switching the Claude Code account in two clicks (the second one confirms).
struct AccountsBoard: View {
    @Environment(AppModel.self) private var model
    @State private var confirming: String?

    var body: some View {
        let report = model.accounts
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.accounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(account.email).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                if account.active { Pill(text: L("en uso"), color: Theme.success) }
                                if let plan = account.plan { Pill(text: plan) }
                            }
                            Text([account.agent, account.organization ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).opacity(0.5).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        switchButton(account, enabled: report.switcherPath != nil)
                    }
                    if account.windows.isEmpty {
                        let window = model.agentUsage.recent(agent: account.agent, hours: 5)
                        Text(L("%@ tokens en 5 h · %@ en 7 días", compact(window.billable), compact(model.agentUsage.total(agent: account.agent).billable)))
                            .font(.system(size: 11).monospacedDigit()).opacity(0.6)
                    } else {
                        HStack(spacing: 12) {
                            ForEach(account.windows.prefix(3)) { window in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(L(window.name)).font(.system(size: 10, weight: .medium)).opacity(0.5)
                                        Spacer(minLength: 2)
                                        Text("\(Int(window.percent.rounded()))%").font(.system(size: 11).monospacedDigit())
                                    }
                                    UsageBar(fraction: window.percent / 100, tint: Theme.level(window.percent / 100))
                                    Text(window.willLast == false ? L("se agota antes del reinicio") : window.resetsAt.map { L("reinicia %@", relative($0)) } ?? " ")
                                        .font(.system(size: 9)).foregroundStyle(window.willLast == false ? Theme.warning : Color.primary.opacity(0.45)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .padding(10)
                .glass(cornerRadius: 10)
            }
            if report.accounts.isEmpty {
                Text(L("No hay ninguna sesión iniciada en Claude Code ni en Codex.")).font(.system(size: 11)).opacity(0.5).padding(10)
            }
            if report.switcherPath == nil, report.accounts.contains(where: { $0.agent == "Claude Code" }) {
                Text(L("Con claude-swap instalado verás aquí todas tus cuentas de Claude Code, sus límites reales y podrás cambiar entre ellas."))
                    .font(.system(size: 10)).opacity(0.45).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func switchButton(_ account: AgentAccount, enabled: Bool) -> some View {
        if model.switchingAccount == account.id {
            ProgressView().controlSize(.small)
        } else if enabled, account.agent == "Claude Code", !account.active, account.number != nil {
            if confirming == account.id {
                HStack(spacing: 4) {
                    Button(L("Cancelar")) { confirming = nil }.buttonStyle(.bordered)
                    Button(L("Confirmar")) {
                        confirming = nil
                        Task { await model.switchClaudeAccount(account) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else {
                Button(L("Usar")) { confirming = account.id }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.switchingAccount != nil)
            }
        }
    }
}

// MARK: - Copilot

/// The copilot from the island: what it is doing, its plan, the decisions it waits for, and its answer.
struct CopilotBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let conversation = model.conversation
        VStack(alignment: .leading, spacing: 10) {
            if conversation.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("El copiloto no está trabajando.")).font(.system(size: 12)).opacity(0.6)
                    Text(L("Cuando le preguntes algo, aquí verás su plan y podrás aprobar o rechazar lo que proponga sin cambiar de ventana."))
                        .font(.system(size: 11)).opacity(0.45).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if let question = conversation.last(where: { $0.kind == .user })?.text {
                    Text(question).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.ink(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                HStack(spacing: 8) {
                    if model.agentRunning { ProgressView().controlSize(.small) }
                    Text(model.copilotStatus).font(.system(size: 12)).opacity(0.75).lineLimit(1).shimmer(model.agentRunning)
                    Spacer()
                    if model.agentRunning {
                        Button(L("Detener")) { model.stopAgent() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                if let plan = conversation.last(where: { $0.kind == .plan }) { PlanCard(steps: plan.plan) }
                if let error = conversation.last, error.kind == .error {
                    Label(error.text, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Theme.danger)
                }
                if let answer = conversation.last(where: { $0.kind == .answer }), !model.agentRunning || answer.revealed > 0 {
                    let shown = String(answer.text.prefix(max(answer.revealed, 0)))
                    Text((try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(shown))
                        .font(.system(size: 12)).lineSpacing(3).lineLimit(9).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Decisions: every card of the last question, pending ones first.
                ForEach(decisions) { ApprovalCard(item: $0) }
            }
            HStack(spacing: 8) {
                Button(conversation.isEmpty ? L("Preguntar al copiloto") : L("Abrir la conversación")) {
                    model.paletteWantsChat = !conversation.isEmpty
                    model.deckOpen = false
                    IslandController.shared.update(model: model)
                    PaletteController.shared.show()
                }
                .buttonStyle(.bordered)
                Spacer()
                if !conversation.isEmpty {
                    Button(L("Quitar de la isla")) { model.dismissCopilotFromIsland() }.buttonStyle(.bordered)
                        .help(L("Deja de mostrar esta conversación arriba; sigue en el historial"))
                }
            }
            .controlSize(.small)
        }
    }

    private var decisions: [AgentItem] {
        let conversation = model.conversation
        let start = conversation.lastIndex { $0.kind == .user } ?? 0
        let cards = conversation[start...].filter { $0.kind == .approval }
        return cards.filter { $0.approval == .pending } + cards.filter { $0.approval != .pending }
    }
}

/// One line under the island's header while the copilot works or waits: status, and the first decision right there.
struct CopilotStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pending = model.pendingApprovals
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if model.agentRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: pending.isEmpty ? "sparkles" : "hand.raised.fill").font(.system(size: 11))
                        .foregroundStyle(pending.isEmpty ? Color.primary.opacity(0.7) : Theme.warning)
                }
                Text(model.copilotStatus).font(.system(size: 12, weight: .medium)).lineLimit(1).shimmer(model.agentRunning)
                Spacer(minLength: 6)
                Button(L("Ver")) {
                    model.deckTab = DeckTab.copilot.rawValue
                    model.deckOpen = true
                }
                .buttonStyle(.bordered).controlSize(.small)
                Button { model.dismissCopilotFromIsland() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).opacity(0.6).help(L("Quitar de la isla"))
            }
            if let first = pending.first, let action = first.action, !model.agentRunning {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title(for: action)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(action.reason).font(.system(size: 11)).opacity(0.6).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Button(L("Rechazar")) { model.reject(first.id) }.buttonStyle(.bordered)
                    Button(L("Aprobar")) { Task { await model.approve(first.id) } }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

@MainActor
extension AppModel {
    /// Stops showing the current conversation on the island until the copilot has something new.
    func dismissCopilotFromIsland() {
        copilotDismissedAt = conversation.count
        deckOpen = false
        IslandController.shared.update(model: self)
    }

    /// Human title of an action the copilot proposes ("Cerrar java", "Reducir la RAM de Docker a 4096 MB"…).
    func title(for action: AIAction) -> String {
        let target = unredact(action.target)
        switch action.type {
        case "kill_group": return L("Cerrar %@", snapshot.group(target)?.name ?? target)
        case "kill_process": return L("Matar %@ (PID %@)", Int32(target).flatMap { snapshot.processes[$0]?.name } ?? L("proceso"), target)
        case "restart_service": return L("Reiniciar %@", Int32(target).flatMap { snapshot.service(rootPid: $0)?.1.label } ?? L("servicio %@", target))
        case "clean_cache": return L("Limpiar %@", Fmt.tilde(target)) + (cacheEntry(path: action.target).map { " · \(Fmt.bytes($0.sizeBytes))" } ?? "")
        case "set_memory_limit": return L("Avisar si %@ pasa de %d MB", snapshot.group(target)?.name ?? target, Int(action.value ?? 0))
        case "set_docker_memory": return L("Reducir la RAM de Docker a %d MB", Int(action.value ?? 0))
        case "run_tool": return Toolkit.recipe(target).map { L($0.title) } ?? target
        default: return action.type
        }
    }
}
