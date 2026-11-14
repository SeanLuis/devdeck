import AppKit
import DevDeckCore
import Foundation

/// One agent session as the panel shows it: where it works, what it costs right now and what it spawned.
struct AgentWorkRow: Identifiable {
    enum State { case working, idle, recent }

    let id: String
    let agent: String
    let folder: String
    var name: String?
    var state: State
    /// "cli", editor extension, desktop app…
    var entry: String?
    var model: String = ""
    var load: ProcessTreeLoad?
    var tokens: TokenCount?
    var lastActivity: Date?
    var file: String?
    var pid: Int32?
    var subagents: [AgentSession] = []
    /// Last step taken (tool call or text), for sessions that are open.
    var activity: AgentActivity?
    var waitingFor: String?

    var folderName: String {
        if folder.isEmpty || folder == "/" { return "" }
        return folder == NSHomeDirectory() ? "~" : (folder as NSString).lastPathComponent
    }
    var activeSubagents: [AgentSession] { subagents.filter { Date().timeIntervalSince($0.lastActivity) < AgentWork.activeWindow } }
}

struct AgentWork {
    /// A transcript written this recently counts as "working now".
    static let activeWindow: TimeInterval = 150

    var live: [AgentWorkRow] = []
    var recent: [AgentWorkRow] = []

    /// Live rows grouped by agent, heaviest agent first.
    var liveByAgent: [(agent: String, rows: [AgentWorkRow])] {
        Dictionary(grouping: live, by: \.agent)
            .map { (agent: $0.key, rows: $0.value.sorted { ($0.load?.memoryBytes ?? 0) > ($1.load?.memoryBytes ?? 0) }) }
            .sorted { a, b in
                a.rows.reduce(0) { $0 + ($1.load?.memoryBytes ?? 0) } > b.rows.reduce(0) { $0 + ($1.load?.memoryBytes ?? 0) }
            }
    }
}

@MainActor
extension AppModel {
    func refreshLiveSessions() async {
        let sessions = await Task.detached(priority: .utility) { LiveAgentSessions.claude() }.value
        if sessions != liveSessions { liveSessions = sessions }
        // What each open session is doing: the tail of its transcript.
        let files = Dictionary(agentUsage.sessions.filter { $0.agent == "Claude Code" && !$0.isSubagent }.map { ($0.sessionID, $0.file) }) { a, _ in a }
        let wanted = sessions.compactMap { live in files[live.sessionID].map { (live.sessionID, $0) } }
        let found = await Task.detached(priority: .utility) {
            var out: [String: AgentActivity] = [:]
            for (id, file) in wanted { out[id] = AgentActivityReader.claude(transcript: file) }
            return out
        }.value
        if found != activities { activities = found }
        announceWaiting(waitTracker.update(sessions))
    }

    /// An agent that worked for a while and now waits is easy to miss behind other windows.
    func announceWaiting(_ events: [AgentWaitEvent]) {
        guard settings.notifyAgentWaiting, !headless else { return }
        for event in events {
            let session = event.session
            let folder = session.cwd == NSHomeDirectory() ? "~" : (session.cwd as NSString).lastPathComponent
            let place = [folder, session.name ?? "", session.waitingFor ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            let title = event.reason == .needsInput ? L("Claude Code necesita tu respuesta") : L("Claude Code terminó y espera")
            let body = L("%@ — trabajó %@", place.isEmpty ? "Claude Code" : place, Fmt.duration(since: Date().addingTimeInterval(-event.worked)))
            pushAlert(AlertEvent(title: title, message: body, severity: .info))
            presentAlert(title: title, body: body, severity: .info)
            notify(title: title, body: body, severity: .info)
        }
    }

    func refreshAccounts(force: Bool = false) async {
        guard !demo else { return }
        // Codex: ask its own CLI every couple of minutes; a failed read keeps the last good one.
        if force || Date().timeIntervalSince(codexAskedAt) > 120, let binary = LoginEnvironment.which("codex", env: loginEnv) {
            codexAskedAt = Date()
            let env = loginEnv
            if let plan = await Task.detached(priority: .utility, operation: { CodexLimits.read(binary: binary, env: env) }).value { codexLive = plan }
        }
        let codexPlan = codexLive ?? agentUsage.codexPlan
        var usage: [String: AccountUsage] = [:]
        if let vault, !vault.accounts().isEmpty {
            // Show what is known at once; the readings that are due arrive a moment later.
            usage = await accountUsage.snapshot()
            accounts = await AgentAccounts.load(env: loginEnv, codexPlan: codexPlan, vault: vault, usage: usage)
            usage = await accountUsage.refresh(vault: vault, force: force)
        }
        accounts = await AgentAccounts.load(env: loginEnv, codexPlan: codexPlan, vault: vault, usage: usage)
        applySessionPace()
        suggestAccountSwitch()
    }

    /// "Runs out in ~35 min at this pace" for the 5-hour window of the Claude Code account in use.
    func applySessionPace() {
        guard let index = accounts.accounts.firstIndex(where: { $0.agent == "Claude Code" && $0.active }),
              let w = accounts.accounts[index].windows.firstIndex(where: { $0.name == "5 h" }) else { return }
        let window = accounts.accounts[index].windows[w]
        guard let resets = window.resetsAt else { return }
        let now = Date()
        accounts.accounts[index].windows[w].runsOutAt = SessionPace.runsOut(
            percent: window.percent, resetsAt: resets,
            windowTokens: agentUsage.tokens(agent: "Claude Code", since: resets.addingTimeInterval(-5 * 3600), now: now),
            lastHourTokens: agentUsage.tokens(agent: "Claude Code", since: now.addingTimeInterval(-3600), now: now), now: now)
    }

    /// When the account in use is nearly spent and another has room: says so with a button ("suggest"),
    /// or switches by itself and tells afterwards ("auto"). The user chooses which, the threshold, and which
    /// accounts are left out.
    func suggestAccountSwitch() {
        let mode = settings.accountSwitchMode
        guard mode != "off", switchingAccount == nil,
              let suggestion = accounts.switchSuggestion(threshold: settings.accountSwitchPercent, excluded: Set(settings.accountSwitchExcluded)) else { return }
        let from = suggestion.from.alias ?? suggestion.from.email, to = suggestion.to.alias ?? suggestion.to.email
        let title = L("%@ al %d%% en la ventana de %@", from, Int(suggestion.window.percent.rounded()), L(suggestion.window.name))
        let room = suggestion.to.windows.map(\.percent).max() ?? 0
        if mode == "auto" {
            // Never bounce between accounts: one automatic switch every ten minutes at most.
            guard Date().timeIntervalSince(lastAutoSwitch) > 600 else { return }
            lastAutoSwitch = Date()
            Task {
                await switchClaudeAccount(suggestion.to)
                let body = L("Cambio automático a %@ (%d%% usado).", to, Int(room.rounded()))
                presentAlert(title: title, body: body, severity: .info, seconds: 12)
                notify(title: title, body: body, severity: .info)
            }
            return
        }
        guard suggestedSwitches.insert(suggestion.key).inserted else { return }
        let body = L("%@ tiene margen (%d%%). ¿Cambiar Claude Code a esa cuenta?", to, Int(room.rounded()))
        pushAlert(AlertEvent(title: title, message: body, severity: .info))
        presentAlert(title: title, body: body, severity: .warning, actionLabel: L("Cambiar de cuenta"), seconds: 25) { [weak self] in
            Task { await self?.switchClaudeAccount(suggestion.to) }
        }
    }

    func setAccountExcluded(_ account: AgentAccount, _ excluded: Bool) {
        guard let id = account.vaultID else { return }
        settings.accountSwitchExcluded.removeAll { $0 == id }
        if excluded { settings.accountSwitchExcluded.append(id) }
        saveSettings()
    }

    /// Open Claude Code sessions: they keep the login they started with until they are restarted.
    var openClaudeSessions: Int { liveSessions.filter { snapshot.processes[$0.pid] != nil }.count }

    /// Codex processes running now: each one keeps its login in memory and may write it back over a switch.
    var openCodexProcesses: Int {
        snapshot.processes.values.filter { $0.isMine && ($0.name == "codex" || $0.executablePath.hasSuffix("/codex")) }.count
    }

    /// Switches the Claude Code login. Only ever called from an explicit confirmation.
    func switchClaudeAccount(_ account: AgentAccount) async {
        guard switchingAccount == nil else { return }
        switchingAccount = account.id
        defer { switchingAccount = nil }
        if let id = account.vaultID, let vault {
            let codex = account.agent == AccountVault.codex
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    if codex { try vault.switchCodex(to: id) } else { try vault.switchClaude(to: id) }
                    return nil
                } catch { return error.localizedDescription }
            }.value
            if let failure {
                show(L("No se pudo cambiar de cuenta: %@", failure))
            } else {
                show(L("%@ ahora usa %@", account.agent, account.email))
                pushAlert(AlertEvent(title: L("Cuenta cambiada"), message: account.email, severity: .info))
            }
            await refreshAccounts()
            return
        }
        guard let number = account.number, let path = accounts.switcherPath else { return }
        let result = await AgentAccounts.switchClaude(to: number, switcherPath: path, env: loginEnv)
        if result.ok {
            show(L("Claude Code ahora usa %@", account.email))
            pushAlert(AlertEvent(title: L("Cuenta cambiada"), message: account.email, severity: .info))
        } else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            show(L("No se pudo cambiar de cuenta: %@", String(detail.suffix(160))))
        }
        await refreshAccounts()
    }

    /// Copies claude-swap's accounts into DevDeck's own store. claude-swap's data is left as it is.
    func adoptClaudeSwapAccounts() async {
        guard let vault else { return }
        let report = await Task.detached(priority: .userInitiated) { vault.importFromClaudeSwap() }.value
        var message = L("%d cuentas importadas", report.imported.count)
        if !report.failed.isEmpty { message += " · " + L("sin credenciales: %@", report.failed.joined(separator: ", ")) }
        show(message)
        pushAlert(AlertEvent(title: L("Cuentas importadas"), message: message, severity: report.failed.isEmpty ? .info : .warning))
        await refreshAccounts(force: true)
    }

    /// Saves the login an agent is using now, so it can be switched back to later.
    func saveCurrentAccount(agent: String) async {
        guard let vault else { return }
        let outcome: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            Result { try (agent == AccountVault.codex ? vault.addCurrentCodex() : vault.addCurrent()).email }
        }.value
        switch outcome {
        case .success(let email): show(L("Cuenta guardada: %@", email))
        case .failure(let error): show(error.localizedDescription)
        }
        await refreshAccounts(force: true)
    }

    /// Opens the agent's own login in Terminal and saves the new login when it appears.
    /// The account in use now is saved first, so logging into another one loses nothing.
    func addAccount(agent: String) {
        guard let vault, addingAccount == nil else { return }
        guard let binary = LoginEnvironment.which(AccountLogin.binary(for: agent), env: loginEnv) else {
            show(L("No se encontró el comando de %@ en este Mac.", agent))
            return
        }
        let file = store.directory.appendingPathComponent("login-\(AccountLogin.binary(for: agent)).command")
        do {
            try AccountLogin.script(agent: agent, binaryPath: binary).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            show(error.localizedDescription)
            return
        }
        addingAccount = agent
        addingTask = Task { [weak self] in
            let before: String? = await Task.detached {
                _ = try? (agent == AccountVault.codex ? vault.addCurrentCodex() : vault.addCurrent())
                return vault.liveKey(agent: agent)
            }.value
            NSWorkspace.shared.open(file)
            var saved: String?
            // Ten minutes to finish in the browser; after that it stops waiting (the login itself is not undone).
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                let now = await Task.detached { vault.liveKey(agent: agent) }.value
                guard let now, now != before else { continue }
                // The agent writes its files in two steps: give it a moment before taking the pair.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                saved = await Task.detached { try? (agent == AccountVault.codex ? vault.addCurrentCodex() : vault.addCurrent()).email }.value
                if saved != nil { break }
            }
            guard let self else { return }
            self.addingAccount = nil
            try? FileManager.default.removeItem(at: file)
            if let saved {
                self.show(L("Cuenta guardada: %@", saved))
                self.pushAlert(AlertEvent(title: L("Cuenta añadida"), message: "\(agent) · \(saved)", severity: .info))
                await self.refreshAccounts(force: true)
            } else if !Task.isCancelled {
                self.show(L("No apareció ninguna cuenta nueva de %@.", agent))
            }
        }
    }

    func cancelAddAccount() {
        addingTask?.cancel()
        addingTask = nil
        addingAccount = nil
    }

    func renameAccount(_ account: AgentAccount, alias: String) async {
        guard let id = account.vaultID, let vault else { return }
        vault.rename(id, alias: alias)
        await refreshAccounts()
    }

    func moveAccount(_ account: AgentAccount, by offset: Int) async {
        guard let id = account.vaultID, let vault else { return }
        vault.move(id, by: offset)
        await refreshAccounts()
    }

    func removeAccount(_ account: AgentAccount) async {
        guard let id = account.vaultID, let vault else { return }
        do {
            try vault.remove(id)
            show(L("Cuenta quitada: %@", account.email))
        } catch {
            show(error.localizedDescription)
        }
        await refreshAccounts()
    }

    /// Crosses what the agents log (sessions, subagents, tokens) with the processes that are alive now.
    func agentWork() -> AgentWork {
        var work = AgentWork()
        let processes = snapshot.processes
        let children = ProcessTreeLoad.childrenIndex(processes)
        let sessions = agentUsage.sessions
        var shown = Set<String>()       // transcript files already listed as live
        var claimed = Set<Int32>()      // pids that belong to a listed Claude Code session

        // Claude Code registers every open session with its pid, folder and whether it is busy.
        for live in liveSessions {
            guard processes[live.pid] != nil else { continue }
            let load = ProcessTreeLoad.of(root: live.pid, processes: processes, children: children)
            var queue = [live.pid]
            while let pid = queue.popLast() { if claimed.insert(pid).inserted { queue += children[pid] ?? [] } }
            let transcript = sessions.first { $0.agent == "Claude Code" && $0.sessionID == live.sessionID }
            if let transcript { shown.insert(transcript.id) }
            let subagents = agentUsage.subagents(of: live.sessionID)
            let busy = live.isBusy || subagents.contains { Date().timeIntervalSince($0.lastActivity) < AgentWork.activeWindow }
            work.live.append(AgentWorkRow(id: "live-\(live.sessionID)", agent: "Claude Code", folder: live.cwd, name: live.name,
                                          state: busy ? .working : .idle, entry: live.entrypoint, model: transcript?.model ?? "",
                                          load: load, tokens: transcript?.tokens, lastActivity: transcript?.lastActivity ?? live.updatedAt,
                                          file: transcript?.file, pid: live.pid, subagents: subagents,
                                          activity: activities[live.sessionID], waitingFor: live.waitingFor))
        }

        // Every other agent: its processes grouped by the folder they work in.
        for group in snapshot.groups where group.kind == .agent {
            var byFolder: [String: ProcessTreeLoad] = [:]
            for pid in group.pids where !claimed.contains(pid) {
                guard let process = processes[pid] else { continue }
                // Apps and helpers sit in "/" or in a temp folder: that is not a place where work happens.
                var folder = process.cwd ?? ""
                if folder == "/" || folder.hasPrefix("/private/var/") || folder.hasPrefix("/var/folders/") || folder.hasPrefix("/private/tmp/") { folder = "" }
                var load = byFolder[folder] ?? ProcessTreeLoad()
                load.memoryBytes += process.memoryBytes
                load.cpuPercent += process.cpuPercent
                load.processCount += 1
                byFolder[folder] = load
            }
            for (folder, load) in byFolder where load.memoryBytes > 24 << 20 {
                let transcript = sessions.first { $0.agent == group.name && !$0.isSubagent && $0.project == folder && !shown.contains($0.id) }
                let fresh = transcript.map { Date().timeIntervalSince($0.lastActivity) < AgentWork.activeWindow } ?? false
                if let transcript { shown.insert(transcript.id) }
                work.live.append(AgentWorkRow(id: "proc-\(group.id)-\(folder)", agent: group.name, folder: folder, name: transcript?.title,
                                              state: fresh || load.cpuPercent > 15 ? .working : .idle, model: transcript?.model ?? "",
                                              load: load, tokens: transcript?.tokens, lastActivity: transcript?.lastActivity,
                                              file: transcript?.file, subagents: transcript.map { agentUsage.subagents(of: $0.sessionID) } ?? []))
            }
        }

        for session in sessions where !session.isSubagent && !shown.contains(session.id) {
            work.recent.append(AgentWorkRow(id: "recent-\(session.id)", agent: session.agent, folder: session.project,
                                            name: session.title, state: .recent, model: session.model, tokens: session.tokens,
                                            lastActivity: session.lastActivity, file: session.file,
                                            subagents: agentUsage.subagents(of: session.sessionID)))
            if work.recent.count >= 10 { break }
        }
        return work
    }
}

// MARK: - Budgets

@MainActor
extension AppModel {
    func budgetStatuses() -> [BudgetStatus] {
        budgets.map { Budgets.status($0, usage: agentUsage, accounts: accounts) }
    }

    func saveBudgets() {
        store.save(budgets, "budgets.json")
        checkBudgets()
    }

    func addBudget(_ budget: Budget) {
        budgets.removeAll { $0.kind == budget.kind && $0.target == budget.target && $0.period == budget.period }
        budgets.append(budget)
        saveBudgets()
    }

    func removeBudget(_ id: UUID) {
        budgets.removeAll { $0.id == id }
        saveBudgets()
    }

    /// Announces the budgets that just crossed 80 % or 100 %. It only tells: nothing is stopped.
    func checkBudgets() {
        guard !demo, !budgets.isEmpty else { return }
        let before = budgetFired
        let firings = Budgets.evaluate(budgets, usage: agentUsage, accounts: accounts, fired: &budgetFired)
        if budgetFired != before { store.save(budgetFired, "budget-state.json") }
        for firing in firings {
            let title = firing.level >= 100 ? L("Presupuesto superado") : L("Presupuesto al %d%%", firing.level)
            let message = budgetName(firing.status.budget) + " · " + budgetProgress(firing.status)
            let severity: AlertSeverity = firing.level >= 100 ? .warning : .info
            pushAlert(AlertEvent(title: title, message: message, severity: severity))
            presentAlert(title: title, body: message, severity: severity)
            notify(title: title, body: message, severity: severity)
        }
    }

    func budgetName(_ budget: Budget) -> String {
        let period = budget.kind == .account ? L(budget.windowName) : (budget.period == .day ? L("hoy") : L("7 días"))
        switch budget.kind {
        case .all: return L("Todos los agentes") + " · " + period
        case .agent, .account: return budget.target + " · " + period
        case .project: return (budget.target as NSString).lastPathComponent + " · " + period
        }
    }

    func budgetProgress(_ status: BudgetStatus) -> String {
        if status.budget.kind == .account {
            return status.measurable ? L("%d%% de un tope del %d%%", Int(status.used.rounded()), Int(status.budget.limit)) : L("la cuenta no publica su límite")
        }
        return L("%@ de %@ tokens", compact(UInt64(max(0, status.used))), compact(UInt64(max(0, status.budget.limit))))
    }
}

// MARK: - Leftovers

@MainActor
extension AppModel {
    /// Processes agents started and abandoned. Listed for the user to decide; nothing is closed without a click.
    func agentLeftovers() -> [AgentLeftover] {
        var listening: [Int32: [UInt16]] = [:]
        for binding in snapshot.ports { listening[binding.pid, default: []].append(binding.port) }
        return AgentLeftovers.find(processes: snapshot.processes, listening: listening)
    }

    func close(leftovers: [AgentLeftover]) async {
        let pids = leftovers.flatMap(\.pids)
        guard !pids.isEmpty else { return }
        let memory = leftovers.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let result = await terminateVerified(pids)
        let message = L("%d procesos cerrados, %@ liberados", result.graceful + result.forced, Fmt.bytes(memory))
        show(message)
        pushAlert(AlertEvent(title: L("Restos de agentes"), message: message, severity: .info))
    }
}
