import DevDeckCore
import SwiftUI

/// What is known about one project's repository, worked out once when the project is opened (never while drawing).
struct ProjectWork: Equatable {
    var repo: GitRepo?
    /// Last agent session in each worktree, by the worktree's path.
    var lastSession: [String: SessionEntry] = [:]
    /// Sessions that worked anywhere in the project, newest first.
    var sessions: [SessionEntry] = []
    var measured = false
}

extension AppModel {
    /// Reads a project's branches, worktrees and sessions. Quick first; the disk size of extra worktrees comes after.
    func loadProjectWork(root: String) async {
        guard projectWorkLoading != root else { return }
        if demo {
            projectWork[root] = demoProjectWork(root: root)
            return
        }
        projectWorkLoading = root
        defer { if projectWorkLoading == root { projectWorkLoading = nil } }
        if sessionLibrary.isEmpty { await loadSessions() }
        let (env, library) = (loginEnv, sessionLibrary)
        func build(measure: Bool) async -> ProjectWork {
            await Task.detached(priority: .utility) {
                var work = ProjectWork()
                work.repo = await GitWork.repo(containing: root, env: env, measure: measure)
                work.measured = measure
                let trees = work.repo?.worktrees ?? []
                let base = (root as NSString).standardizingPath
                for entry in library {
                    let folder = (entry.folder as NSString).standardizingPath
                    let tree = trees.filter { folder == $0.path || folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
                    guard tree != nil || folder == base || folder.hasPrefix(base + "/") else { continue }
                    work.sessions.append(entry)
                    if let tree, work.lastSession[tree.path] == nil { work.lastSession[tree.path] = entry }
                }
                return work
            }.value
        }
        projectWork[root] = await build(measure: false)
        // Sizes only matter when there are extra worktrees to weigh.
        if (projectWork[root]?.repo?.worktrees.count ?? 0) > 1 { projectWork[root] = await build(measure: true) }
    }

    private func demoProjectWork(root: String) -> ProjectWork {
        func tree(_ path: String, _ branch: String, main: Bool = false, changes: Int = 0, ahead: Int = 0, days: Double, size: UInt64? = nil) -> GitWorktree {
            var t = GitWorktree(path: path)
            t.branch = branch; t.isMain = main; t.changes = changes; t.ahead = ahead
            t.lastCommit = Date().addingTimeInterval(-days * 86_400); t.sizeBytes = size
            return t
        }
        var work = ProjectWork(measured: true)
        var trees = [tree(root, "main", main: true, changes: 4, ahead: 1, days: 0.1)]
        if root.hasSuffix("storefront") {
            trees.append(tree(root + "/.claude/worktrees/checkout-tests", "agent/checkout-tests", changes: 12, days: 0.02, size: 640 << 20))
            trees.append(tree(root + "/.claude/worktrees/old-cart-api", "agent/old-cart-api", days: 26, size: 1_480 << 20))
        }
        work.repo = GitRepo(root: root, worktrees: trees)
        work.sessions = sessionLibrary.filter { $0.folder == root }
        if let first = work.sessions.first { work.lastSession[root] = first }
        return work
    }

    func removeWorktree(_ worktree: GitWorktree, from repo: GitRepo, project root: String) async {
        let result = await GitWork.remove(worktree, from: repo, env: loginEnv)
        if result.ok {
            show(L("Worktree quitado: %@", worktree.branch ?? (worktree.path as NSString).lastPathComponent))
        } else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            show(L("Git no lo quitó: %@", String(detail.suffix(180))))
        }
        await loadProjectWork(root: root)
    }
}

/// The agents' side of a project: the branch and worktree each one works in, and the sessions to pick up again.
struct ProjectWorkSection: View {
    @Environment(AppModel.self) private var model
    let root: String
    @State private var allSessions = false

    var body: some View {
        let work = model.projectWork[root]
        VStack(alignment: .leading, spacing: 18) {
            if let repo = work?.repo {
                Panel(L("Ramas y worktrees")) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Few open sessions against this project's few worktrees: cheap enough to match here.
                        let live = model.liveSessions
                        ForEach(repo.worktrees) { worktree in
                            WorktreeRow(root: root, repo: repo, worktree: worktree,
                                        live: live.filter { deepest($0.cwd, in: repo)?.path == worktree.path },
                                        last: work?.lastSession[worktree.path])
                        }
                    }
                }
            }
            if let sessions = work?.sessions, !sessions.isEmpty {
                Panel(L("Sesiones de agentes aquí")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sessions.prefix(allSessions ? 30 : 4)) { SessionRow(entry: $0, hit: nil) }
                        if sessions.count > 4, !allSessions {
                            Button(L("Ver %d más", sessions.count - 4)) { allSessions = true }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .task(id: root) { await model.loadProjectWork(root: root) }
    }

    private func deepest(_ folder: String, in repo: GitRepo) -> GitWorktree? {
        repo.worktrees.filter { folder == $0.path || folder.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }
}

struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let root: String
    let repo: GitRepo
    let worktree: GitWorktree
    let live: [LiveAgentSession]
    let last: SessionEntry?

    var body: some View {
        let leftover = worktree.isLeftover(hasSession: !live.isEmpty)
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(live.contains(where: \.isBusy) ? Theme.success : live.isEmpty ? Theme.ink(0.18) : Theme.warning).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(worktree.branch ?? L("sin rama (%@)", worktree.head)).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1)
                    if !worktree.isMain { Pill(text: "worktree") }
                    if worktree.changes > 0 { Pill(text: plural(worktree.changes, "%d cambio sin confirmar", "%d cambios sin confirmar"), color: Theme.warning) }
                    if worktree.ahead > 0 { Pill(text: L("%d por subir", worktree.ahead)) }
                    if worktree.behind > 0 { Pill(text: L("%d por detrás", worktree.behind)) }
                    if leftover { Pill(text: worktree.missing ? L("carpeta borrada") : L("sin uso"), color: Theme.danger) }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let size = worktree.sizeBytes {
                Text(Fmt.bytes(size)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
            if !worktree.isMain, !worktree.missing {
                Button { model.openTerminal(at: worktree.path) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help("Terminal")
                Button { Task { await model.openAgent(in: worktree.path) } } label: { Image(systemName: "sparkle") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Abre Claude Code en esta carpeta, con la cuenta de este proyecto"))
            }
            if !worktree.isMain, live.isEmpty {
                KillButton(title: L("¿Quitar el worktree %@?", worktree.branch ?? (worktree.path as NSString).lastPathComponent),
                           message: L("Se borra su carpeta; la rama y sus commits se quedan. Git se niega si hay cambios sin confirmar."),
                           label: L("Quitar worktree"), compact: true) {
                    await model.removeWorktree(worktree, from: repo, project: root)
                }
                .buttonStyle(.plain).foregroundStyle(leftover ? Theme.danger : Theme.tertiaryText)
            }
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let busy = live.first(where: \.isBusy) {
            parts.append(L("%@ trabajando", "Claude Code") + (busy.name.map { " · " + $0 } ?? ""))
        } else if !live.isEmpty {
            parts.append(L("%@ abierto, en espera", "Claude Code"))
        } else if let last {
            parts.append("\(last.agent) · \(last.title) · \(relative(last.modified))")
        }
        if let commit = worktree.lastCommit { parts.append(L("último commit %@", relative(commit))) }
        if !worktree.isMain { parts.append(Fmt.tilde(worktree.path)) }
        return parts.isEmpty ? Fmt.tilde(worktree.path) : parts.joined(separator: " · ")
    }
}
