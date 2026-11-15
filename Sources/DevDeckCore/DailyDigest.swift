import Foundation

public struct DigestCommit: Hashable, Sendable {
    public let hash: String
    public let subject: String
    public init(hash: String, subject: String) { self.hash = hash; self.subject = subject }
}

/// What happened in one project on one day.
public struct DigestProject: Identifiable, Hashable, Sendable {
    public var id: String { folder }
    public let folder: String
    public var tokens = TokenCount()
    /// At API list prices; nil when no model of the day has a known price.
    public var dollars: Double?
    public var agents: [String] = []
    /// Titles of the sessions that were active that day.
    public var sessions: [String] = []
    public var commits: [DigestCommit] = []

    public var name: String { (folder as NSString).lastPathComponent }
}

/// One day of agent work, per project: what was asked, what it cost and what was committed.
public struct DailyDigest: Hashable, Sendable {
    public let day: String
    public var projects: [DigestProject] = []

    public var tokens: TokenCount { projects.reduce(TokenCount()) { $0 + $1.tokens } }
    public var dollars: Double? {
        let known = projects.compactMap(\.dollars)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
    public var commitCount: Int { projects.reduce(0) { $0 + $1.commits.count } }
    public var sessionCount: Int { projects.reduce(0) { $0 + $1.sessions.count } }
}

public enum DailyDigests {
    /// Folder a piece of work is filed under: the repository it belongs to when known, itself otherwise.
    static func home(of folder: String, roots: [String]) -> String {
        roots.filter { folder == $0 || folder.hasPrefix($0 + "/") }.max { $0.count < $1.count } ?? folder
    }

    /// `roots`: repository folders; work in a subfolder or in a worktree inside one is counted with it.
    public static func build(day: String, usage: AgentUsageReport, prices: PriceTable, sessions: [SessionEntry],
                             commits: [String: [DigestCommit]] = [:], roots: [String] = []) -> DailyDigest {
        var projects: [String: DigestProject] = [:]
        func project(_ folder: String) -> String {
            let key = home(of: folder, roots: roots)
            if projects[key] == nil { projects[key] = DigestProject(folder: key) }
            return key
        }
        for (key, tokens) in usage.buckets where key.day == day && !key.project.isEmpty {
            let id = project(key.project)
            projects[id]!.tokens = projects[id]!.tokens + tokens
            if let cost = prices.cost(tokens, model: key.model) { projects[id]!.dollars = (projects[id]!.dollars ?? 0) + cost }
            if !projects[id]!.agents.contains(key.agent) { projects[id]!.agents.append(key.agent) }
        }
        for session in sessions where AgentUsageReport.dayString(session.modified) == day && !session.folder.isEmpty {
            let id = project(session.folder)
            if !projects[id]!.sessions.contains(session.title) { projects[id]!.sessions.append(session.title) }
            if !projects[id]!.agents.contains(session.agent) { projects[id]!.agents.append(session.agent) }
        }
        for (folder, list) in commits where !list.isEmpty {
            let id = project(folder)
            projects[id]!.commits += list
        }
        var digest = DailyDigest(day: day)
        digest.projects = projects.values
            .filter { $0.tokens.billable > 0 || !$0.commits.isEmpty || !$0.sessions.isEmpty }
            .sorted { ($0.tokens.billable, $0.commits.count, $1.folder) > ($1.tokens.billable, $1.commits.count, $0.folder) }
        return digest
    }

    /// Commits made in a repository on a local calendar day, on any branch.
    public static func commits(repo: String, day: String, env: [String: String]? = nil) async -> [DigestCommit] {
        let result = await Shell.run(GitWork.git, ["-C", repo, "log", "--all", "--no-merges", "--since=\(day) 00:00:00", "--until=\(day) 23:59:59",
                                                   "--format=%h%x09%s", "-n", "60"], env: env, timeout: 12)
        guard result.ok else { return [] }
        return parseCommits(result.stdout)
    }

    static func parseCommits(_ text: String) -> [DigestCommit] {
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, seen.insert(parts[1]).inserted else { return nil }   // the same change on two branches counts once
            return DigestCommit(hash: parts[0], subject: parts[1])
        }
    }

    static func tokensText(_ value: UInt64) -> String {
        let v = Double(value)
        switch v {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.0fK", v / 1_000)
        default: return "\(value)"
        }
    }

    static func dollarsText(_ value: Double) -> String { String(format: value < 10 ? "$%.2f" : "$%.0f", value) }

    /// The day as text to paste into a stand-up or a work log.
    public static func markdown(_ digest: DailyDigest) -> String {
        var lines = ["# \(digest.day)", ""]
        var head = "\(tokensText(digest.tokens.billable)) tokens"
        if let dollars = digest.dollars { head += " · ~\(dollarsText(dollars))" }
        head += " · \(digest.commitCount) commits"
        lines += [head, ""]
        for project in digest.projects {
            var title = "## \(project.name)"
            var facts: [String] = []
            if project.tokens.billable > 0 { facts.append("\(tokensText(project.tokens.billable)) tokens") }
            if let dollars = project.dollars { facts.append("~\(dollarsText(dollars))") }
            if !project.agents.isEmpty { facts.append(project.agents.joined(separator: ", ")) }
            if !facts.isEmpty { title += " — " + facts.joined(separator: " · ") }
            lines.append(title)
            for session in project.sessions { lines.append("- \(session)") }
            for commit in project.commits { lines.append("- `\(commit.hash)` \(commit.subject)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The same, as plain data for the command line and for agents.
    public static func report(_ digest: DailyDigest) -> [String: Any] {
        var out: [String: Any] = ["day": digest.day, "tokens": digest.tokens.billable, "commits": digest.commitCount, "sessions": digest.sessionCount]
        if let dollars = digest.dollars { out["list_price_usd"] = NSDecimalNumber(string: String(format: "%.2f", dollars)) }
        out["projects"] = digest.projects.map { project -> [String: Any] in
            var row: [String: Any] = ["folder": project.folder, "tokens": project.tokens.billable, "agents": project.agents,
                                      "sessions": project.sessions, "commits": project.commits.map { ["hash": $0.hash, "subject": $0.subject] }]
            if let dollars = project.dollars { row["list_price_usd"] = NSDecimalNumber(string: String(format: "%.2f", dollars)) }
            return row
        }
        return out
    }

    /// Reads everything the digest needs from this Mac.
    public static func load(day: String, env: [String: String], prices: PriceTable, usage: AgentUsageReport? = nil,
                            sessions: [SessionEntry]? = nil) async -> DailyDigest {
        let scanned: AgentUsageReport
        if let usage { scanned = usage } else { scanned = await AgentUsageScanner().scan(days: 7, env: env) }
        let library = sessions ?? SessionLibrary.list()
        let folders = Set(scanned.buckets.keys.filter { $0.day == day }.map(\.project))
            .union(library.filter { AgentUsageReport.dayString($0.modified) == day }.map(\.folder))
        var commits: [String: [DigestCommit]] = [:]
        var roots: [String] = []
        for folder in folders.sorted() where !folder.isEmpty && folder != NSHomeDirectory() {
            guard FileManager.default.fileExists(atPath: folder) else { continue }
            let top = await Shell.run(GitWork.git, ["-C", folder, "worktree", "list", "--porcelain"], env: env, timeout: 8)
            guard top.ok, let root = GitWork.parseWorktrees(top.stdout).first?.path, !roots.contains(root) else { continue }
            roots.append(root)
            commits[root] = await DailyDigests.commits(repo: root, day: day, env: env)
        }
        return build(day: day, usage: scanned, prices: prices, sessions: library, commits: commits, roots: roots)
    }
}
