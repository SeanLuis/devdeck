import Foundation

/// A checkout of a repository: the main folder or one of its worktrees.
public struct GitWorktree: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    /// nil when HEAD is detached.
    public var branch: String?
    public var head: String = ""
    /// The repository's own folder, as opposed to an extra worktree.
    public var isMain = false
    /// Git says its folder is gone.
    public var missing = false
    public var locked = false
    /// Files changed or untracked.
    public var changes = 0
    public var ahead = 0
    public var behind = 0
    public var lastCommit: Date?
    public var sizeBytes: UInt64?

    public init(path: String) { self.path = path }

    /// An extra worktree nobody is working in: nothing to commit and no commit in a while. Safe to remove.
    public func isLeftover(hasSession: Bool, now: Date = Date(), after days: Double = 14) -> Bool {
        guard !isMain, !locked, !hasSession else { return false }
        if missing { return true }
        guard changes == 0, let last = lastCommit else { return false }
        return now.timeIntervalSince(last) > days * 86_400
    }
}

public struct GitRepo: Identifiable, Hashable, Sendable {
    public var id: String { root }
    public let root: String
    public var worktrees: [GitWorktree]

    public init(root: String, worktrees: [GitWorktree]) { self.root = root; self.worktrees = worktrees }

    public var name: String { (root as NSString).lastPathComponent }
}

/// Branches and worktrees of the repositories the agents work in. Reads with `git`; the only thing it ever
/// changes is removing a worktree the user picked, and git itself refuses when there is uncommitted work.
public enum GitWork {
    public static let git = "/usr/bin/git"

    /// `git worktree list --porcelain` → worktrees, the main one first.
    public static func parseWorktrees(_ text: String) -> [GitWorktree] {
        var out: [GitWorktree] = []
        var current: GitWorktree?
        func close() { if let c = current { out.append(c) }; current = nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { close(); continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "worktree":
                close()
                current = GitWorktree(path: value)
            case "HEAD": current?.head = String(value.prefix(8))
            case "branch": current?.branch = value.hasPrefix("refs/heads/") ? String(value.dropFirst(11)) : value
            case "locked": current?.locked = true
            case "prunable": current?.missing = true
            default: break
            }
        }
        close()
        if !out.isEmpty { out[0].isMain = true }
        return out
    }

    /// `git status --porcelain=v1 -b` → files changed, and how far the branch is from its upstream.
    public static func parseStatus(_ text: String) -> (changes: Int, ahead: Int, behind: Int) {
        var changes = 0, ahead = 0, behind = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("##") {
                func number(after word: String) -> Int {
                    guard let range = line.range(of: word + " ") else { return 0 }
                    return Int(line[range.upperBound...].prefix { $0.isNumber }) ?? 0
                }
                ahead = number(after: "ahead")
                behind = number(after: "behind")
            } else {
                changes += 1
            }
        }
        return (changes, ahead, behind)
    }

    /// The repository that holds `folder`, with every worktree and its state. nil when it is not a repository.
    public static func repo(containing folder: String, env: [String: String]? = nil, measure: Bool = true) async -> GitRepo? {
        let listed = await Shell.run(git, ["-C", folder, "worktree", "list", "--porcelain"], env: env, timeout: 8)
        guard listed.ok else { return nil }
        var worktrees = parseWorktrees(listed.stdout)
        guard let main = worktrees.first else { return nil }
        for index in worktrees.indices where !worktrees[index].missing {
            let path = worktrees[index].path
            guard FileManager.default.fileExists(atPath: path) else { worktrees[index].missing = true; continue }
            let status = await Shell.run(git, ["-C", path, "status", "--porcelain=v1", "-b"], env: env, timeout: 15)
            if status.ok {
                let parsed = parseStatus(status.stdout)
                worktrees[index].changes = parsed.changes
                worktrees[index].ahead = parsed.ahead
                worktrees[index].behind = parsed.behind
            }
            let log = await Shell.run(git, ["-C", path, "log", "-1", "--format=%ct"], env: env, timeout: 8)
            if let seconds = Double(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) { worktrees[index].lastCommit = Date(timeIntervalSince1970: seconds) }
            // What an extra worktree takes on disk (its own copy of the files and whatever was installed in it).
            if measure, !worktrees[index].isMain {
                let du = await Shell.run("/usr/bin/du", ["-sk", path], timeout: 20)
                if let kb = UInt64(du.stdout.split(separator: "\t").first ?? "") { worktrees[index].sizeBytes = kb << 10 }
            }
        }
        return GitRepo(root: main.path, worktrees: worktrees)
    }

    /// The repositories behind a list of folders, each one once, in the order given.
    public static func scan(folders: [String], env: [String: String]? = nil, limit: Int = 24) async -> [GitRepo] {
        var repos: [GitRepo] = []
        var covered = Set<String>()
        for folder in folders where repos.count < limit {
            let path = (folder as NSString).standardizingPath
            guard !path.isEmpty, path != "/", path != NSHomeDirectory(), !covered.contains(path),
                  FileManager.default.fileExists(atPath: path) else { continue }
            covered.insert(path)
            guard let repo = await repo(containing: path, env: env) else { continue }
            guard !repos.contains(where: { $0.root == repo.root }) else { continue }
            for worktree in repo.worktrees { covered.insert(worktree.path) }
            repos.append(repo)
        }
        return repos
    }

    /// The worktree a folder is in: the deepest one that contains it.
    public static func worktree(of folder: String, in repos: [GitRepo]) -> GitWorktree? {
        let path = (folder as NSString).standardizingPath
        return repos.flatMap(\.worktrees)
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Removes an extra worktree. Git refuses when it holds uncommitted work; that answer is returned as is.
    public static func remove(_ worktree: GitWorktree, from repo: GitRepo, env: [String: String]? = nil) async -> ShellResult {
        if worktree.missing { return await Shell.run(git, ["-C", repo.root, "worktree", "prune"], env: env, timeout: 20) }
        return await Shell.run(git, ["-C", repo.root, "worktree", "remove", worktree.path], env: env, timeout: 60)
    }
}
