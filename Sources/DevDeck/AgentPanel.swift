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
    }

    func refreshAccounts() async {
        accounts = await AgentAccounts.load(env: loginEnv, codexPlan: agentUsage.codexPlan)
    }

    /// Switches the Claude Code login through claude-swap. Only ever called from an explicit confirmation.
    func switchClaudeAccount(_ account: AgentAccount) async {
        guard let number = account.number, let path = accounts.switcherPath, switchingAccount == nil else { return }
        switchingAccount = account.id
        defer { switchingAccount = nil }
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
                                          file: transcript?.file, pid: live.pid, subagents: subagents))
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
