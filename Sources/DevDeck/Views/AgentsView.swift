import Charts
import DevDeckCore
import SwiftUI

/// Coding agents on this Mac: what is installed, what is running, and how many tokens each one burned.
struct AgentsView: View {
    @Environment(AppModel.self) private var model
    /// One group at a time: what is running, the accounts, or what was spent.
    @AppStorage("agentsTab") private var tab = "activity"

    var body: some View {
        let report = model.agentUsage
        let today = AgentUsageReport.dayString(Date())
        let work = model.agentWork()
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroHeader(section: .agents, title: L("Agentes de IA"), subtitle: L("Claude Code, Codex y otros: qué corre, cuánta RAM usan y cuántos tokens gastan")) {
                    Button {
                        Task { await model.refreshAgentUsage(); await model.refreshAccounts(force: true) }
                    } label: {
                        if model.agentScanning { ProgressView().controlSize(.small) } else { Label(L("Actualizar"), systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.agentScanning)
                }

                Picker("", selection: $tab) {
                    Text(L("Actividad")).tag("activity")
                    Text(L("Cuentas y límites")).tag("accounts")
                    Text(L("Consumo")).tag("usage")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                if tab == "activity" {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(report.installs.filter { used($0, report) }) { install in
                            AgentCard(install: install, today: report.total(agent: install.name, day: today),
                                      week: report.total(agent: install.name))
                        }
                    }

                    let unused = report.installs.filter { !used($0, report) }
                    if !unused.isEmpty {
                        Text(L("Instalados sin uso esta semana: %@", unused.map(\.name).joined(separator: ", ")))
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                    AgentWorkPanel(work: work)
                    LeftoversPanel()
                    Panel(L("Sesiones recientes")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(work.recent) { row in AgentSessionRow(row: row) }
                            if work.recent.isEmpty {
                                Text(L("Sin sesiones en los últimos %d días", report.days)).font(.caption).foregroundStyle(Theme.tertiaryText)
                            }
                        }
                    }
                }

                if tab == "accounts" {
                    AccountsPanel()
                    BudgetsPanel()
                }

                if tab == "usage" {
                    HStack(alignment: .top, spacing: 12) {
                        Panel(L("Tokens por día · últimos %@ días", "\(report.days)")) {
                            TokensByDayChart(report: report).frame(height: 200)
                        }
                        Panel(L("Por modelo")) {
                            VStack(spacing: 8) {
                                let models = report.byModel()
                                let maxValue = Double(models.first?.tokens.billable ?? 1)
                                ForEach(models.prefix(6), id: \.model) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.model).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                            Spacer()
                                            if let dollars = model.prices.cost(item.tokens, model: item.model) {
                                                Text(costText(dollars)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiaryText)
                                            }
                                            Text(compact(item.tokens.billable)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                                        }
                                        UsageBar(fraction: Double(item.tokens.billable) / max(maxValue, 1), tint: Theme.tint)
                                    }
                                }
                                if models.isEmpty { Text(L("Sin datos todavía")).font(.caption).foregroundStyle(Theme.tertiaryText) }
                            }
                        }
                        .frame(maxWidth: 340)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Panel(L("Proyectos con más consumo")) {
                            VStack(spacing: 8) {
                                ForEach(Array(report.byProject().enumerated()), id: \.offset) { _, item in
                                    HStack(spacing: 10) {
                                        IconTile(symbol: "folder", size: 22)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text((item.project as NSString).lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text("\(item.agent) · \(Fmt.tilde(item.project))").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 1) {
                                            Text(compact(item.tokens.billable)).font(.system(size: 13).monospacedDigit())
                                            let cost = report.cost(model.prices) { $0.agent == item.agent && $0.project == item.project }
                                            Text(cost.hasPrice ? cost.text + " · " + L("%d respuestas", item.tokens.messages) : L("%d respuestas", item.tokens.messages))
                                                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiaryText)
                                        }
                                    }
                                }
                                if report.buckets.isEmpty { Text(L("Sin datos todavía")).font(.caption).foregroundStyle(Theme.tertiaryText) }
                            }
                        }
                    }
                    Panel(L("Consumo del propio DevDeck")) { OwnUsagePanel() }
                    Text(L("Los tokens se leen de los registros locales de cada agente (Claude Code, Codex, Devin, OpenCode, Gemini CLI). “Tokens” = entrada + salida + escritura de caché; las lecturas de caché se muestran aparte. Los límites de cada cuenta se leen de la propia cuenta."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    Text(L("El coste (≈ $) es lo que valdrían esos tokens a precio de lista de la API; con una suscripción no se paga por token. Los modelos sin precio conocido no suman: puedes añadirlos en prices.json, en la carpeta de datos de DevDeck."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(28)
        }
    }
}

extension AgentsView {
    /// An agent earns a card when it is running or spent something this week.
    func used(_ install: AgentInstall, _ report: AgentUsageReport) -> Bool {
        report.total(agent: install.name).messages > 0
            || model.snapshot.groups.contains { $0.kind == .agent && $0.name.lowercased().hasPrefix(install.name.lowercased().prefix(5)) }
    }
}

/// Who is working right now, per agent: each session with its folder, load, tokens and the subagents it spawned.
struct AgentWorkPanel: View {
    let work: AgentWork

    var body: some View {
        Panel(L("Trabajando ahora")) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(work.liveByAgent.enumerated()), id: \.element.agent) { index, entry in
                    if index > 0 { Divider().overlay(Theme.ink(0.05)) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            AgentIcon(name: entry.agent, size: 18)
                            Text(entry.agent).font(.system(size: 13, weight: .semibold))
                            let busy = entry.rows.filter { $0.state == .working }.count
                            Text(busy > 0 ? L("%d de %d trabajando", busy, entry.rows.count) : L("%d en espera", entry.rows.count))
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                            Spacer()
                            Text(Fmt.bytes(entry.rows.reduce(0) { $0 + ($1.load?.memoryBytes ?? 0) }))
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        }
                        ForEach(entry.rows) { row in AgentSessionRow(row: row) }
                    }
                }
                if work.live.isEmpty {
                    Text(L("Ningún agente abierto ahora mismo.")).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }
}

struct AgentSessionRow: View {
    @Environment(AppModel.self) private var model
    let row: AgentWorkRow
    @State private var showFinished = false

    var body: some View {
        let active = row.activeSubagents
        let finished = row.subagents.filter { sub in !active.contains { $0.id == sub.id } }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(dot).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if let name = row.name, !name.isEmpty, name != title {
                            Text(name).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        }
                        if !row.subagents.isEmpty {
                            Pill(text: active.isEmpty ? plural(row.subagents.count, "%d subagente", "%d subagentes") : plural(active.count, "%d subagente activo", "%d subagentes activos"),
                                 color: active.isEmpty ? .secondary : Theme.success)
                        }
                    }
                    Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                    if let waiting = row.waitingFor, !waiting.isEmpty {
                        Text(L("Espera: %@", waiting)).font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(1)
                    } else if let activity = row.activity {
                        HStack(spacing: 5) {
                            if let tool = activity.tool { Text(tool).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiaryText) }
                            Text(activity.detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.tail)
                            if row.state != .working, let at = activity.at { Text("· " + relative(at)).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText) }
                        }
                    }
                }
                Spacer(minLength: 8)
                if let load = row.load {
                    metric("RAM", Fmt.bytes(load.memoryBytes))
                    metric("CPU", Fmt.percent(load.cpuPercent))
                }
                metric("Tokens", row.tokens.map { compact($0.billable) } ?? "—")
                if let file = row.file, !file.hasSuffix(".db") {
                    Button { model.reveal(file) } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless).help(L("Mostrar el registro de la sesión"))
                } else {
                    Color.clear.frame(width: 16, height: 1)
                }
            }
            if !active.isEmpty || !finished.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(active) { SubagentRow(session: $0, active: true) }
                    if !finished.isEmpty {
                        Button { withAnimation(.snappy(duration: 0.2)) { showFinished.toggle() } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(showFinished ? 90 : 0))
                                Text(plural(finished.count, "%d subagente terminado", "%d subagentes terminados")).font(.system(size: 11))
                                Text("· " + compact(finished.reduce(0) { $0 + $1.tokens.billable })).font(.system(size: 11).monospacedDigit())
                            }
                            .foregroundStyle(Theme.tertiaryText)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showFinished { ForEach(finished.prefix(12)) { SubagentRow(session: $0, active: false) } }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ink(0.10)).frame(width: 1).padding(.leading, 3) }
            }
        }
    }

    private var title: String {
        if !row.folderName.isEmpty { return row.folderName }
        if let name = row.name, !name.isEmpty { return name }
        return row.state == .recent ? row.agent : L("Aplicación y servicios")
    }

    private var dot: Color {
        switch row.state {
        case .working: return Theme.success
        case .idle: return Theme.ink(0.30)
        case .recent: return Theme.ink(0.14)
        }
    }

    private var caption: String {
        var parts: [String] = []
        switch row.state {
        case .working: parts.append(L("trabajando"))
        case .idle: parts.append(L("en espera"))
        case .recent:
            parts.append(row.agent)
            if let date = row.lastActivity { parts.append(relative(date)) }
        }
        if !row.model.isEmpty { parts.append(row.model) }
        if let entry = row.entry, !entry.isEmpty { parts.append(entry) }
        if !row.folder.isEmpty, row.folder != "/" { parts.append(Fmt.tilde(row.folder)) }
        return parts.joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 12).monospacedDigit())
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

struct SubagentRow: View {
    let session: AgentSession
    let active: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if active { ProgressView().controlSize(.mini).scaleEffect(0.7) }
                else { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiaryText) }
            }
            .frame(width: 12, height: 12)
            Text(session.title ?? L("Subagente")).font(.system(size: 12)).foregroundStyle(active ? Color.primary : Theme.secondaryText).lineLimit(1)
            if let type = session.agentType { Text(type).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.tertiaryText).lineLimit(1) }
            Spacer(minLength: 8)
            Text(compact(session.tokens.billable)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
            Text(relative(session.lastActivity)).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).frame(width: 96, alignment: .trailing)
        }
    }
}

/// Logins of each agent with their limits. Switching always asks first.
struct AccountsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingImport = false

    var body: some View {
        let report = model.accounts
        Panel(L("Cuentas y límites")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(report.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 { Divider().overlay(Theme.ink(0.05)).padding(.vertical, 9) }
                    AccountRow(account: account, canSwitch: report.native || report.switcherPath != nil)
                }
                if report.accounts.isEmpty {
                    Text(L("No hay ninguna sesión iniciada en Claude Code ni en Codex.")).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
                if report.native {
                    Divider().overlay(Theme.ink(0.05)).padding(.vertical, 12)
                    AccountSwitchControls()
                }
                if model.vault != nil {
                    HStack(spacing: 8) {
                        if report.adoptable > 0 {
                            Button(L("Importar las %d cuentas de claude-swap", report.adoptable)) { confirmingImport = true }.buttonStyle(.borderedProminent)
                        }
                        if let agent = model.addingAccount {
                            ProgressView().controlSize(.small)
                            Text(L("Esperando a que termines de iniciar sesión en %@…", agent)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            Button(L("Cancelar")) { model.cancelAddAccount() }.buttonStyle(.bordered)
                        } else {
                            Menu(L("Añadir cuenta")) {
                                Button("Claude Code") { model.addAccount(agent: "Claude Code") }
                                Button("Codex") { model.addAccount(agent: "Codex") }
                            }
                            .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                            Text(L("Abre el inicio de sesión del propio agente en el navegador. La cuenta en uso se guarda antes; la nueva queda en uso."))
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(.top, 12)
                }
            }
        }
        .confirmationDialog(L("¿Importar las cuentas de claude-swap?"), isPresented: $confirmingImport) {
            Button(L("Importar")) { Task { await model.adoptClaudeSwapAccounts() } }
        } message: {
            Text(L("DevDeck copia cada sesión guardada a su propio almacén del llavero, sin volver a iniciar sesión. No cambia la cuenta en uso ni borra nada de claude-swap."))
        }
    }
}

struct AccountRow: View {
    @Environment(AppModel.self) private var model
    let account: AgentAccount
    let canSwitch: Bool
    @State private var confirming = false
    @State private var confirmingRemoval = false
    @State private var renaming = false
    @State private var alias = ""

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AgentIcon(name: account.agent, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.alias ?? account.email).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if account.active { Pill(text: L("en uso"), color: Theme.success) }
                    if let plan = account.plan { Pill(text: plan) }
                    if excluded { Pill(text: L("sin cambio automático")) }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            if account.windows.isEmpty {
                estimate
            } else {
                ForEach(account.windows.prefix(3)) { LimitGauge(window: $0, stale: account.isStale()) }
            }
            ZStack(alignment: .trailing) {
                Color.clear.frame(height: 1)
                if model.switchingAccount == account.id {
                    ProgressView().controlSize(.small)
                } else if !account.active, account.number != nil, account.vaultID != nil || (canSwitch && account.agent == "Claude Code") {
                    Button(L("Usar")) { confirming = true }.buttonStyle(.bordered).disabled(model.switchingAccount != nil)
                } else if canSave {
                    Button(L("Guardar")) { Task { await model.saveCurrentAccount(agent: account.agent) } }.buttonStyle(.bordered)
                        .help(L("Guarda esta sesión en DevDeck para poder volver a ella sin iniciar sesión de nuevo"))
                }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if account.vaultID != nil {
                Button(L("Renombrar…")) { alias = account.alias ?? ""; renaming = true }
                if account.agent == "Claude Code" {
                    Toggle(L("Excluir del cambio automático"), isOn: Binding(get: { excluded }, set: { model.setAccountExcluded(account, $0) }))
                }
                Button(L("Subir")) { Task { await model.moveAccount(account, by: -1) } }
                Button(L("Bajar")) { Task { await model.moveAccount(account, by: 1) } }
                Divider()
                Button(L("Quitar de DevDeck…"), role: .destructive) { confirmingRemoval = true }
            }
        }
        .confirmationDialog(L("¿Cambiar %@ a %@?", account.agent, account.email), isPresented: $confirming) {
            Button(L("Cambiar de cuenta")) { Task { await model.switchClaudeAccount(account) } }
        } message: {
            Text(switchMessage)
        }
        .confirmationDialog(L("¿Quitar %@ de DevDeck?", account.email), isPresented: $confirmingRemoval) {
            Button(L("Quitar"), role: .destructive) { Task { await model.removeAccount(account) } }
        } message: {
            Text(account.active ? L("Claude Code seguirá usando esta cuenta; DevDeck solo deja de guardarla.")
                 : L("Se borra la sesión guardada. Para volver a usar esta cuenta habrá que iniciar sesión otra vez."))
        }
        .alert(L("Nombre para la cuenta"), isPresented: $renaming) {
            TextField(account.email, text: $alias)
            Button(L("Guardar")) { Task { await model.renameAccount(account, alias: alias) } }
            Button(L("Cancelar"), role: .cancel) {}
        }
    }

    /// The login in use that DevDeck does not keep yet. While claude-swap still manages the Claude Code accounts
    /// they are imported together, not one by one.
    private var canSave: Bool {
        guard model.vault != nil, account.active, account.vaultID == nil, account.email != "—", account.email != "API key" else { return false }
        if account.agent == "Codex" { return true }
        return account.agent == "Claude Code" && (model.accounts.native || model.accounts.adoptable == 0)
    }

    private var excluded: Bool { account.vaultID.map(model.settings.accountSwitchExcluded.contains) ?? false }

    private var switchMessage: String {
        if account.agent == "Codex" {
            let running = model.openCodexProcesses
            let base = L("Las sesiones nuevas de Codex usarán esta cuenta.")
            return running > 0 ? L("Codex está abierto: ciérralo antes de cambiar, o puede volver a escribir la cuenta anterior.") + " " + base : base
        }
        let open = model.openClaudeSessions
        let base = L("Las sesiones nuevas usarán esta cuenta. Las que ya están abiertas pueden necesitar reiniciarse.")
        return open > 0 ? plural(open, "Hay %d sesión de Claude Code abierta.", "Hay %d sesiones de Claude Code abiertas.") + " " + base : base
    }

    private var caption: String {
        var parts = [account.agent]
        if account.alias != nil { parts.append(account.email) }
        if let number = account.number { parts.append(L("cuenta %d", number)) }
        if let organization = account.organization, !organization.isEmpty { parts.append(organization) }
        if let note = account.note { parts.append(L(note)) }
        if account.isStale(), let read = account.usageFetched { parts.append(L("leído %@", relative(read))) }
        if let expires = account.loginExpires, expires.timeIntervalSinceNow < 3 * 86400 {
            parts.append(L("la sesión caduca %@", relative(expires)))
        }
        return parts.joined(separator: " · ")
    }

    /// No percentage published by the agent: show what was actually spent, clearly marked as local data.
    private var estimate: some View {
        let window = model.agentUsage.recent(agent: account.agent, hours: 5)
        let week = model.agentUsage.total(agent: account.agent)
        return VStack(alignment: .trailing, spacing: 2) {
            if account.vaultID != nil, !account.active {
                Text(L("Límites sin leer todavía")).font(.system(size: 12))
            } else {
                Text(L("%@ tokens en 5 h · %@ en 7 días", compact(window.billable), compact(week.billable))).font(.system(size: 12).monospacedDigit())
            }
            Text(L("Uso medido en este Mac; el agente no publica su límite.")).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        }
    }
}

/// What happens when the account in use is nearly spent: nothing, a suggestion, or an automatic switch.
struct AccountSwitchControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Al acercarse al límite")).font(.system(size: 13, weight: .medium))
                Text(help).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(2)
            }
            Spacer(minLength: 12)
            Picker("", selection: $model.settings.accountSwitchMode) {
                Text(L("No hacer nada")).tag("off")
                Text(L("Sugerir")).tag("suggest")
                Text(L("Cambiar sola")).tag("auto")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Picker("", selection: $model.settings.accountSwitchPercent) {
                ForEach([50.0, 60, 70, 75, 80, 85, 90, 95], id: \.self) { Text("\(Int($0))%").tag($0) }
            }
            .labelsHidden().frame(width: 76).disabled(model.settings.accountSwitchMode == "off")
        }
        .onChange(of: model.settings.accountSwitchMode) { model.saveSettings() }
        .onChange(of: model.settings.accountSwitchPercent) { model.saveSettings() }
    }

    private var help: String {
        switch model.settings.accountSwitchMode {
        case "auto": return L("Cuando la cuenta en uso pasa del umbral, Claude Code cambia a la que más margen tenga y te avisa. Clic derecho en una cuenta para excluirla.")
        case "suggest": return L("Cuando la cuenta en uso pasa del umbral, DevDeck propone la que más margen tenga; el cambio lo confirmas tú.")
        default: return L("DevDeck no propone ni cambia de cuenta.")
        }
    }
}

struct LimitGauge: View {
    let window: UsageWindow
    /// An old reading: drawn faint, and a window that has already reset shows no figure at all.
    var stale = false

    private var expired: Bool { window.resetsAt.map { $0 < Date() } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L(window.name)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 2)
                Text(expired ? "—" : "\(Int(window.percent.rounded()))%").font(.system(size: 12).monospacedDigit())
            }
            UsageBar(fraction: expired ? 0 : window.percent / 100, tint: Theme.level(window.percent / 100))
            Text(detail).font(.system(size: 10)).foregroundStyle(warns ? Theme.warning : Theme.tertiaryText).lineLimit(1)
        }
        .frame(width: 128)
        .opacity(stale || expired ? 0.5 : 1)
    }

    private var warns: Bool { !expired && (window.willLast == false || window.runsOutAt != nil) }

    private var detail: String {
        if expired { return L("ya se reinició; sin lectura nueva") }
        if let runsOut = window.runsOutAt { return L("se agota %@", relative(runsOut)) }
        if window.willLast == false { return L("se agota antes del reinicio") }
        guard let resets = window.resetsAt else { return " " }
        return L("reinicia %@", relative(resets))
    }
}

/// Singular or plural form of a counted phrase, localized.
func plural(_ count: Int, _ one: String, _ many: String) -> String {
    L(count == 1 ? one : many, count)
}

/// "hace 3 min" / "en 2 h", in the app's language.
func relative(_ date: Date) -> String {
    var style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated)
    style.locale = L10n.language.locale
    return date.formatted(style)
}

/// "≈ $12.40" for a priced amount.
func costText(_ dollars: Double) -> String {
    var estimate = CostEstimate()
    estimate.dollars = dollars
    estimate.pricedTokens = 1
    return estimate.text
}

func compact(_ value: UInt64) -> String {
    let v = Double(value)
    switch v {
    case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
    case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
    case 1_000...: return String(format: "%.0fK", v / 1_000)
    default: return "\(value)"
    }
}

struct AgentCard: View {
    @Environment(AppModel.self) private var model
    let install: AgentInstall
    let today: TokenCount
    let week: TokenCount

    var body: some View {
        let group = model.snapshot.groups.first { $0.kind == .agent && $0.name.lowercased().hasPrefix(install.name.lowercased().prefix(5)) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentIcon(name: install.name, size: 28, active: group != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(install.name).font(.system(size: 14, weight: .semibold))
                    Text(install.installed ? (install.version ?? install.binary) : group != nil ? L("aplicación") : L("solo datos, sin CLI")).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                }
                Spacer()
                if let group {
                    Pill(text: L("activo"), color: Theme.success)
                    KillButton(title: L("¿Cerrar %@?", group.name), message: L("%@ procesos, %@.", "\(group.processCount)", Fmt.bytes(group.memoryBytes)), compact: true) {
                        await model.kill(group: group)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 0) {
                stat("RAM", group.map { Fmt.bytes($0.memoryBytes) } ?? "—")
                stat(L("Procesos"), group.map { "\($0.processCount)" } ?? "—")
                stat(L("Hoy"), today.messages > 0 ? compact(today.billable) : "—")
                stat(L("7 días"), week.messages > 0 ? compact(week.billable) : "—")
            }
            if week.cacheRead > 0 {
                let cost = model.agentUsage.cost(model.prices) { $0.agent == install.name }
                Text(cost.hasPrice ? L("%@ en 7 días", cost.text) + " · " + L("%@ leídos de caché", compact(week.cacheRead))
                     : L("%@ leídos de caché · %@ respuestas", compact(week.cacheRead), "\(week.messages)"))
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
        }
        .padding(14)
        .frame(minHeight: 124, alignment: .topLeading)
        .glass(cornerRadius: 12)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            Text(value).font(.system(size: 14, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TokensByDayChart: View {
    let report: AgentUsageReport

    struct Point: Identifiable {
        let id = UUID()
        let day: String
        let agent: String
        let millions: Double
    }

    var body: some View {
        // Every day of the window on the axis, in order, even when only one agent worked that day.
        let days = Array(Set(report.buckets.keys.map(\.day))).sorted()
        let points = days.flatMap { day in
            report.agents.map { agent in
                Point(day: String(day.suffix(5)), agent: agent, millions: Double(report.total(agent: agent, day: day).billable) / 1_000_000)
            }
        }
        if points.isEmpty {
            EmptyHint(title: L("Sin uso registrado"), symbol: "chart.bar", message: L("Cuando uses Claude Code o Codex aparecerá aquí."))
        } else {
            Chart(points) { p in
                BarMark(x: .value(L("Día"), p.day), y: .value(L("M tokens"), p.millions))
                    .foregroundStyle(by: .value(L("Agente"), p.agent))
                    .cornerRadius(2)
            }
            .chartForegroundStyleScale(range: ChartPalette.colors)
            .chartYAxisLabel(L("millones de tokens"))
            .chartLegend(position: .bottom)
        }
    }
}
