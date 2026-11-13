import Foundation

/// A Claude Code session that is open right now, as Claude Code itself registers it in `~/.claude/sessions/<pid>.json`.
public struct LiveAgentSession: Hashable, Sendable, Identifiable {
    public var id: String { sessionID }
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    /// "busy" | "idle" | …
    public let status: String?
    public let name: String?
    /// How it was started: "cli", an editor extension, the desktop app…
    public let entrypoint: String?
    public let startedAt: Date?
    public let updatedAt: Date?

    public var isBusy: Bool { status == "busy" }

    public init(pid: Int32, sessionID: String, cwd: String, status: String?, name: String?, entrypoint: String?, startedAt: Date?, updatedAt: Date?) {
        self.pid = pid; self.sessionID = sessionID; self.cwd = cwd; self.status = status; self.name = name
        self.entrypoint = entrypoint; self.startedAt = startedAt; self.updatedAt = updatedAt
    }
}

public enum LiveAgentSessions {
    public static func claude(home: String = NSHomeDirectory()) -> [LiveAgentSession] {
        let directory = home + "/.claude/sessions"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)) else { return nil }
            return parseClaude(data)
        }
    }

    public static func parseClaude(_ data: Data) -> LiveAgentSession? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (obj["pid"] as? NSNumber)?.int32Value, let session = obj["sessionId"] as? String else { return nil }
        func date(_ key: String) -> Date? {
            (obj[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        }
        return LiveAgentSession(pid: pid, sessionID: session, cwd: (obj["cwd"] as? String) ?? "", status: obj["status"] as? String,
                                name: obj["name"] as? String, entrypoint: obj["entrypoint"] as? String,
                                startedAt: date("startedAt"), updatedAt: date("statusUpdatedAt") ?? date("updatedAt"))
    }
}

/// Memory and CPU of a process and everything it spawned.
public struct ProcessTreeLoad: Hashable, Sendable {
    public var memoryBytes: UInt64 = 0
    public var cpuPercent: Double = 0
    public var processCount = 0

    public init() {}

    /// Children of every process, built once per snapshot.
    public static func childrenIndex(_ processes: [Int32: ProcessRecord]) -> [Int32: [Int32]] {
        var index: [Int32: [Int32]] = [:]
        for (pid, process) in processes { index[process.ppid, default: []].append(pid) }
        return index
    }

    public static func of(root: Int32, processes: [Int32: ProcessRecord], children: [Int32: [Int32]]) -> ProcessTreeLoad {
        var load = ProcessTreeLoad()
        var queue = [root]
        var seen = Set<Int32>()
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted, let process = processes[pid] else { continue }
            load.memoryBytes += process.memoryBytes
            load.cpuPercent += process.cpuPercent
            load.processCount += 1
            queue += children[pid] ?? []
        }
        return load
    }
}
