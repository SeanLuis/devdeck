import Foundation

public struct TokenCount: Codable, Hashable, Sendable {
    public var input: UInt64 = 0
    public var output: UInt64 = 0
    public var cacheRead: UInt64 = 0
    public var cacheWrite: UInt64 = 0
    public var messages: Int = 0

    public init() {}
    public var total: UInt64 { input + output + cacheRead + cacheWrite }
    /// Tokens that were actually generated or freshly processed (cache reads are cheap).
    public var billable: UInt64 { input + output + cacheWrite }

    public static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        var r = a
        r.input += b.input; r.output += b.output; r.cacheRead += b.cacheRead; r.cacheWrite += b.cacheWrite; r.messages += b.messages
        return r
    }
}

/// One slice of usage: agent × day × model × project folder.
public struct UsageKey: Codable, Hashable, Sendable {
    public let agent: String
    public let day: String      // yyyy-MM-dd (local)
    public let model: String
    public let project: String  // cwd
}

public struct AgentInstall: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let binary: String
    public let path: String?
    public var version: String?
    public let dataPath: String?
    public var installed: Bool { path != nil }
}

public struct AgentSession: Identifiable, Hashable, Sendable {
    public var id: String { sessionID.isEmpty ? file : file + "#" + sessionID }
    public let agent: String
    public let file: String
    public let project: String
    public let lastActivity: Date
    public let tokens: TokenCount
    public let model: String
    public let sizeBytes: UInt64
    /// Session id as the agent names it (the transcript's file name for Claude Code).
    public var sessionID: String = ""
    /// For a subagent: the session that spawned it.
    public var parentID: String?
    /// What it is doing: the subagent's task or the session's title.
    public var title: String?
    /// Subagent kind ("general-purpose", "Explore"…).
    public var agentType: String?

    public var isSubagent: Bool { parentID != nil }

    public init(agent: String, file: String, project: String, lastActivity: Date, tokens: TokenCount, model: String, sizeBytes: UInt64,
                sessionID: String = "", parentID: String? = nil, title: String? = nil, agentType: String? = nil) {
        self.agent = agent; self.file = file; self.project = project; self.lastActivity = lastActivity; self.tokens = tokens
        self.model = model; self.sizeBytes = sizeBytes; self.sessionID = sessionID; self.parentID = parentID
        self.title = title; self.agentType = agentType
    }
}

public struct CodexPlan: Hashable, Sendable {
    public var planType: String?
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryResets: Date?
    public var secondaryResets: Date?
    /// "sin créditos" / balance, when Codex reports it.
    public var credits: String?
}

public struct AgentUsageReport: Sendable {
    public var installs: [AgentInstall] = []
    public var buckets: [UsageKey: TokenCount] = [:]
    public var sessions: [AgentSession] = []
    public var codexPlan: CodexPlan?
    public var scannedAt: Date?
    public var days: Int = 7
    /// Tokens per agent per clock hour (epoch hour), to estimate rolling windows.
    public var hourly: [String: [Int: TokenCount]] = [:]

    /// Tokens an agent used in the last `hours` hours (rolling, by clock hour).
    public func recent(agent: String, hours: Int, now: Date = Date()) -> TokenCount {
        let last = Int(now.timeIntervalSince1970 / 3600)
        return (hourly[agent] ?? [:]).reduce(TokenCount()) { acc, pair in pair.key > last - hours ? acc + pair.value : acc }
    }

    /// Subagents spawned by a session, most recent first.
    public func subagents(of sessionID: String) -> [AgentSession] {
        sessionID.isEmpty ? [] : sessions.filter { $0.parentID == sessionID }
    }

    public static let empty = AgentUsageReport()

    public static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public func total(agent: String? = nil, day: String? = nil) -> TokenCount {
        buckets.reduce(TokenCount()) { acc, pair in
            (agent == nil || pair.key.agent == agent) && (day == nil || pair.key.day == day) ? acc + pair.value : acc
        }
    }

    public var agents: [String] { Array(Set(buckets.keys.map(\.agent))).sorted() }

    public func byDay(agent: String) -> [(day: String, tokens: TokenCount)] {
        var map: [String: TokenCount] = [:]
        for (key, value) in buckets where key.agent == agent { map[key.day] = (map[key.day] ?? TokenCount()) + value }
        return map.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public func byProject(limit: Int = 8) -> [(project: String, agent: String, tokens: TokenCount)] {
        var map: [String: TokenCount] = [:]
        for (key, value) in buckets { map[key.agent + "\u{1}" + key.project] = (map[key.agent + "\u{1}" + key.project] ?? TokenCount()) + value }
        return map.sorted { $0.value.billable > $1.value.billable }.prefix(limit).map { pair in
            let parts = pair.key.components(separatedBy: "\u{1}")
            return (parts.count > 1 ? parts[1] : "", parts[0], pair.value)
        }
    }

    public func byModel() -> [(model: String, tokens: TokenCount)] {
        var map: [String: TokenCount] = [:]
        for (key, value) in buckets { map[key.model] = (map[key.model] ?? TokenCount()) + value }
        return map.sorted { $0.value.billable > $1.value.billable }.map { ($0.key, $0.value) }
    }
}

/// Reads what coding agents log locally: Claude Code (`~/.claude/projects/**.jsonl`) and Codex (`~/.codex/sessions/**.jsonl`).
/// Incremental: each file is parsed once and then only its new bytes.
public actor AgentUsageScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var buckets: [UsageKey: TokenCount] = [:]
        var lastMessageID = ""
        var lastModel = ""
        var project = ""
        var codexTotal = TokenCount()
        var codexDay = ""
        var hours: [Int: TokenCount] = [:]
        var title: String?
        var agentType: String?
        var metaRead = false
    }

    private var external: [String: ExternalUsage] = [:]

    private var states: [String: FileState] = [:]
    private var plan: CodexPlan?
    private let home = NSHomeDirectory()
    private var versions: [String: String] = [:]

    public init() {}

    static let known: [(name: String, binary: String, data: String?)] = [
        ("Claude Code", "claude", ".claude/projects"),
        ("Codex", "codex", ".codex/sessions"),
        ("Gemini CLI", "gemini", ".gemini"),
        ("OpenCode", "opencode", ".local/share/opencode"),
        ("Devin", "devin", ".local/share/devin"),
        ("Cursor Agent", "cursor-agent", ".cursor"),
        ("Aider", "aider", nil),
    ]

    /// Which agents exist on this Mac (fast; no transcript parsing).
    public func installs(env: [String: String]) async -> [AgentInstall] {
        var out: [AgentInstall] = []
        for agent in Self.known {
            let path = LoginEnvironment.which(agent.binary, env: env)
            let data = agent.data.map { home + "/" + $0 }
            var install = AgentInstall(name: agent.name, binary: agent.binary, path: path, version: nil,
                                       dataPath: data.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil })
            if let path, install.name == "Claude Code" || install.name == "Codex" {
                if versions[path] == nil {
                    let text = await Shell.run(path, ["--version"], env: env, timeout: 8).stdout
                    versions[path] = text.split(whereSeparator: { $0.isNewline }).first.map { String($0) } ?? ""
                }
                install.version = versions[path]
            }
            if install.installed || install.dataPath != nil { out.append(install) }
        }
        return out
    }

    public func scan(days: Int = 7, env: [String: String]) async -> AgentUsageReport {
        var report = AgentUsageReport()
        report.days = days
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let firstDay = AgentUsageReport.dayString(cutoff)
        let firstHour = Int(cutoff.timeIntervalSince1970 / 3600)

        report.installs = await installs(env: env)

        for (agent, root) in [("Claude Code", home + "/.claude/projects"), ("Codex", home + "/.codex/sessions")] {
            for file in recentFiles(root: root, since: cutoff) {
                var state = states[file.path] ?? FileState()
                if file.size < state.offset { state = FileState() }   // truncated/rotated
                if file.size > state.offset {
                    if agent == "Claude Code" { parseClaude(file.path, &state) } else { parseCodex(file.path, &state) }
                    state.offset = file.size
                    states[file.path] = state
                }
                var sessionTokens = TokenCount()
                for (key, value) in state.buckets where key.day >= firstDay {
                    report.buckets[key] = (report.buckets[key] ?? TokenCount()) + value
                    sessionTokens = sessionTokens + value
                }
                for (hour, value) in state.hours where hour >= firstHour {
                    report.hourly[agent, default: [:]][hour] = (report.hourly[agent]?[hour] ?? TokenCount()) + value
                }
                if sessionTokens.messages > 0 {
                    let url = URL(fileURLWithPath: file.path)
                    let name = url.deletingPathExtension().lastPathComponent
                    var parent: String?
                    // Claude Code keeps subagent transcripts in <session>/subagents/agent-<id>.jsonl.
                    if url.deletingLastPathComponent().lastPathComponent == "subagents" {
                        parent = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                        if !state.metaRead {
                            state.metaRead = true
                            let meta = url.deletingPathExtension().appendingPathExtension("meta.json")
                            if let data = try? Data(contentsOf: meta), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                state.title = (obj["description"] as? String) ?? (obj["name"] as? String)
                                state.agentType = obj["agentType"] as? String
                            }
                            states[file.path] = state
                        }
                    }
                    report.sessions.append(AgentSession(agent: agent, file: file.path, project: state.project, lastActivity: file.modified,
                                                        tokens: sessionTokens, model: state.lastModel, sizeBytes: file.size,
                                                        sessionID: name, parentID: parent, title: state.title, agentType: state.agentType))
                }
            }
        }

        // Agents that keep their history in a database or in JSON files instead of JSONL transcripts.
        let candidates = Set(report.buckets.keys.map(\.project)).union([home])
        for source in ExternalSource.allCases {
            var usage = external[source.rawValue] ?? ExternalUsage()
            source.refresh(&usage, home: home, since: cutoff, projectCandidates: candidates)
            external[source.rawValue] = usage
            for (key, value) in usage.buckets where key.day >= firstDay { report.buckets[key] = (report.buckets[key] ?? TokenCount()) + value }
            for (hour, value) in usage.hours where hour >= firstHour {
                report.hourly[source.agent, default: [:]][hour] = (report.hourly[source.agent]?[hour] ?? TokenCount()) + value
            }
            report.sessions += usage.sessions.values.filter { $0.lastActivity >= cutoff && $0.tokens.messages > 0 }
        }
        report.sessions.sort { $0.lastActivity > $1.lastActivity }
        report.codexPlan = plan
        report.scannedAt = Date()
        return report
    }

    private func recentFiles(root: String, since: Date) -> [(path: String, size: UInt64, modified: Date)] {
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                           includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return [] }
        var out: [(String, UInt64, Date)] = []
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= since else { continue }
            out.append((url.path, UInt64(values?.fileSize ?? 0), modified))
        }
        return out
    }

    /// Calls `body` for every complete new line, without loading the file in memory.
    private func forEachNewLine(_ path: String, from offset: UInt64, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var carry = Data()
        while true {
            // Foundation objects created while parsing must not pile up across gigabytes of transcripts.
            let finished: Bool = autoreleasepool {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return true }
            // Walk the chunk by index; never shift the buffer per line (that is quadratic on big files).
            var buffer = carry.isEmpty ? chunk : carry + chunk
            buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var start = 0
                let count = raw.count
                while start < count, let hit = memchr(base + start, 0x0A, count - start) {
                    let end = base.distance(to: UnsafeRawPointer(hit))
                    if end > start {
                        body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: end - start, deallocator: .none))
                    }
                    start = end + 1
                }
                carry = start < count ? Data(bytes: base + start, count: count - start) : Data()
            }
            buffer = Data()
            // A single gigantic line (tool output) — skip it rather than buffer gigabytes.
            if carry.count > 64 << 20 { carry.removeAll(keepingCapacity: false) }
            return false
            }
            if finished { break }
        }
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let tokenMarker = Data("token_count".utf8)
    private static let metaMarker = Data("session_meta".utf8)
    private static let turnMarker = Data("turn_context".utf8)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(fromISO text: String?) -> Date {
        guard let text else { return Date() }
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
    }

    private func parseClaude(_ path: String, _ state: inout FileState) {
        var local = state
        forEachNewLine(path, from: state.offset) { line in
            guard line.count < 4 << 20, line.range(of: Self.usageMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return }
            // One API response is written as several lines (one per content block): count it once.
            let id = (message["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
            guard id != local.lastMessageID else { return }
            local.lastMessageID = id
            let model = message["model"] as? String ?? "?"
            guard model != "<synthetic>" else { return }
            if let cwd = obj["cwd"] as? String { local.project = cwd }
            local.lastModel = model
            var tokens = TokenCount()
            tokens.input = UInt64(usage["input_tokens"] as? Int ?? 0)
            tokens.output = UInt64(usage["output_tokens"] as? Int ?? 0)
            tokens.cacheRead = UInt64(usage["cache_read_input_tokens"] as? Int ?? 0)
            tokens.cacheWrite = UInt64(usage["cache_creation_input_tokens"] as? Int ?? 0)
            tokens.messages = 1
            let when = Self.date(fromISO: obj["timestamp"] as? String)
            let key = UsageKey(agent: "Claude Code", day: AgentUsageReport.dayString(when), model: model, project: local.project)
            local.buckets[key] = (local.buckets[key] ?? TokenCount()) + tokens
            let hour = Int(when.timeIntervalSince1970 / 3600)
            local.hours[hour] = (local.hours[hour] ?? TokenCount()) + tokens
        }
        state = local
    }

    private func parseCodex(_ path: String, _ state: inout FileState) {
        var local = state
        var newPlan = plan
        forEachNewLine(path, from: state.offset) { line in
            guard line.count < 4 << 20 else { return }
            let isToken = line.range(of: Self.tokenMarker) != nil
            guard isToken || line.range(of: Self.metaMarker) != nil || line.range(of: Self.turnMarker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            if (obj["type"] as? String) == "session_meta" {
                local.project = payload["cwd"] as? String ?? local.project
            }
            if (obj["type"] as? String) == "turn_context", let model = payload["model"] as? String { local.lastModel = model }
            guard (payload["type"] as? String) == "token_count" else { return }
            if let limits = payload["rate_limits"] as? [String: Any] {
                var p = CodexPlan()
                p.planType = limits["plan_type"] as? String
                if let primary = limits["primary"] as? [String: Any] {
                    p.primaryUsedPercent = primary["used_percent"] as? Double
                    if let reset = primary["resets_at"] as? Double { p.primaryResets = Date(timeIntervalSince1970: reset) }
                }
                if let secondary = limits["secondary"] as? [String: Any] {
                    p.secondaryUsedPercent = secondary["used_percent"] as? Double
                    if let reset = secondary["resets_at"] as? Double { p.secondaryResets = Date(timeIntervalSince1970: reset) }
                }
                if let credits = limits["credits"] as? [String: Any] {
                    if (credits["unlimited"] as? Bool) == true { p.credits = "créditos ilimitados" }
                    else if (credits["has_credits"] as? Bool) == true, let balance = credits["balance"] as? String { p.credits = L("créditos: %@", balance) }
                }
                newPlan = p
            }
            guard let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { return }
            // Codex reports cached tokens as part of input; split them so "billable" means the same for every agent.
            let input = UInt64(last["input_tokens"] as? Int ?? 0)
            let cached = UInt64(last["cached_input_tokens"] as? Int ?? 0)
            var tokens = TokenCount()
            tokens.input = input > cached ? input - cached : 0
            tokens.cacheRead = cached
            tokens.cacheWrite = UInt64(last["cache_write_input_tokens"] as? Int ?? 0)
            tokens.output = UInt64(last["output_tokens"] as? Int ?? 0)
            tokens.messages = 1
            let when = Self.date(fromISO: obj["timestamp"] as? String)
            let key = UsageKey(agent: "Codex", day: AgentUsageReport.dayString(when),
                               model: local.lastModel.isEmpty ? "codex" : local.lastModel, project: local.project)
            local.buckets[key] = (local.buckets[key] ?? TokenCount()) + tokens
            let hour = Int(when.timeIntervalSince1970 / 3600)
            local.hours[hour] = (local.hours[hour] ?? TokenCount()) + tokens
        }
        plan = newPlan
        state = local
    }
}
