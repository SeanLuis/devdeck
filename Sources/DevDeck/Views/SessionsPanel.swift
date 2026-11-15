import AppKit
import DevDeckCore
import SwiftUI

extension AppModel {
    /// Reads the list of past sessions (cheap: the start and end of each transcript, and only the files that changed).
    func loadSessions() async {
        guard !sessionsLoading else { return }
        if demo {
            sessionLibrary = agentUsage.sessions.filter { !$0.isSubagent && ["Claude Code", "Codex"].contains($0.agent) }.map {
                SessionEntry(agent: $0.agent, file: $0.file, sessionID: $0.sessionID, project: $0.project, branch: $0.agent == "Codex" ? nil : "main",
                             title: $0.title ?? L("Sesión en %@", ($0.project as NSString).lastPathComponent), modified: $0.lastActivity, sizeBytes: $0.sizeBytes)
            }
            return
        }
        sessionsLoading = true
        let known = Dictionary(sessionLibrary.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        sessionLibrary = await Task.detached(priority: .utility) { SessionLibrary.list(known: known) }.value
        sessionsLoading = false
    }

    /// Searches what was said, newest sessions first. Results arrive as they are found; a new search cancels the old one.
    func searchSessions(_ query: String, days: Int?) {
        sessionSearchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { sessionHits = nil; sessionSearching = false; return }
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        let entries = sessionLibrary.filter { $0.modified >= cutoff }
        sessionHits = []
        sessionSearching = true
        sessionProgress = 0
        sessionSearchTotal = entries.count
        sessionSearchTask = Task { [weak self] in
            var found = 0
            for (index, entry) in entries.enumerated() {
                if Task.isCancelled { return }
                let hit = await Task.detached(priority: .userInitiated) { SessionLibrary.search(text, in: entry) }.value
                if Task.isCancelled { return }
                self?.sessionProgress = index + 1
                if let hit { self?.sessionHits?.append(hit); found += 1 }
                if found >= 80 { break }
            }
            if !Task.isCancelled { self?.sessionSearching = false }
        }
    }

    /// Opens the session again in Terminal, in its own folder, with its own agent.
    func resumeSession(_ entry: SessionEntry) {
        let name = entry.agent == "Codex" ? "codex" : "claude"
        guard let binary = LoginEnvironment.which(name, env: loginEnv) else {
            show(L("No se encontró %@ en este Mac", name))
            return
        }
        if !entry.project.isEmpty, !FileManager.default.fileExists(atPath: entry.project) {
            show(L("La carpeta de esa sesión ya no existe: %@", Fmt.tilde(entry.project)))
            return
        }
        Task {
            // A Claude Code session goes back under the account its folder belongs to.
            if entry.agent == "Claude Code", !(await useFolderAccount(for: entry.project)) { return }
            let file = store.directory.appendingPathComponent("resume-session.command")
            do {
                try SessionLibrary.resumeScript(entry, binaryPath: binary).write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
                NSWorkspace.shared.open(file)
            } catch {
                show(error.localizedDescription)
            }
        }
    }
}

/// Every past session of Claude Code and Codex: find one by what was said in it and open it again.
struct SessionsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var scope = 30
    @State private var agent = ""
    @State private var shown = 40

    var body: some View {
        let hits = model.sessionHits
        let entries = model.sessionLibrary.filter { agent.isEmpty || $0.agent == agent }
        Panel(L("Sesiones")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                        TextField(L("Buscar en lo que se dijo"), text: $query)
                            .textFieldStyle(.plain)
                            .onSubmit { search() }
                        if !query.isEmpty {
                            Button { query = ""; model.searchSessions("", days: nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.ink(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Picker("", selection: $scope) {
                        Text(L("30 días")).tag(30)
                        Text(L("90 días")).tag(90)
                        Text(L("Todo")).tag(0)
                    }
                    .labelsHidden().fixedSize()
                    Picker("", selection: $agent) {
                        Text(L("Todos los agentes")).tag("")
                        Text("Claude Code").tag("Claude Code")
                        Text("Codex").tag("Codex")
                    }
                    .labelsHidden().fixedSize()
                    Button(L("Buscar")) { search() }.buttonStyle(.bordered).disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
                }

                if let hits {
                    let visible = hits.filter { agent.isEmpty || $0.entry.agent == agent }
                    HStack(spacing: 8) {
                        if model.sessionSearching { ProgressView().controlSize(.small) }
                        Text(model.sessionSearching
                             ? L("Buscando… %d de %d sesiones", model.sessionProgress, model.sessionSearchTotal)
                             : plural(visible.count, "%d sesión lo menciona", "%d sesiones lo mencionan"))
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                    ForEach(visible) { hit in SessionRow(entry: hit.entry, hit: hit) }
                } else {
                    if model.sessionsLoading, entries.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Leyendo sesiones…")).font(.caption).foregroundStyle(Theme.tertiaryText) }
                    } else if entries.isEmpty {
                        Text(L("Sin sesiones guardadas en este Mac")).font(.caption).foregroundStyle(Theme.tertiaryText)
                    } else {
                        Text(plural(entries.count, "%d sesión guardada", "%d sesiones guardadas"))
                            .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    }
                    ForEach(entries.prefix(shown)) { entry in SessionRow(entry: entry, hit: nil) }
                    if entries.count > shown {
                        Button(L("Mostrar más")) { shown += 40 }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .task { await model.loadSessions() }
        .onChange(of: scope) { if model.sessionHits != nil { search() } }
    }

    private func search() { model.searchSessions(query, days: scope == 0 ? nil : scope) }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let entry: SessionEntry
    let hit: SessionHit?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentIcon(name: entry.agent, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                if let hit {
                    Text((hit.fromUser ? L("Tú") : entry.agent) + ": " + hit.snippet)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let hit, hit.count > 1 { Pill(text: plural(hit.count, "%d mención", "%d menciones")) }
            Button { model.reveal(entry.file) } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Mostrar el registro en Finder"))
            Button(L("Retomar")) { model.resumeSession(entry) }
                .buttonStyle(.bordered).controlSize(.small).help(L("Abre Terminal en su carpeta y continúa esta sesión"))
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        var parts = [entry.folder.isEmpty ? "—" : (entry.folder as NSString).lastPathComponent]
        if let branch = entry.branch { parts.append(branch) }
        parts.append(relative(entry.modified))
        parts.append(Fmt.bytes(entry.sizeBytes))
        return parts.joined(separator: " · ")
    }
}
