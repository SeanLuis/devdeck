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
    /// What it is blocked on, when Claude Code says so (a permission, a question).
    public var waitingFor: String?

    public var isBusy: Bool { status == "busy" }

    public init(pid: Int32, sessionID: String, cwd: String, status: String?, name: String?, entrypoint: String?, startedAt: Date?, updatedAt: Date?,
                waitingFor: String? = nil) {
        self.waitingFor = waitingFor
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
                                startedAt: date("startedAt"), updatedAt: date("statusUpdatedAt") ?? date("updatedAt"),
                                waitingFor: obj["waitingFor"] as? String)
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

/// An agent session that stopped working and now needs its person.
public struct AgentWaitEvent: Hashable, Sendable {
    public enum Reason: String, Sendable {
        /// The turn ended: the agent answered and waits for the next message.
        case finished
        /// It stopped mid-turn to ask (a permission, a question).
        case needsInput
    }

    public let session: LiveAgentSession
    public let reason: Reason
    /// How long it had been working.
    public let worked: TimeInterval
}

/// Watches the status of the open sessions and reports the moment one goes from working to waiting.
/// Short turns are ignored: nobody walked away from a 10-second answer.
public struct AgentWaitTracker: Sendable {
    private struct State: Sendable { var status: String?; var busySince: Date? }
    private var states: [String: State] = [:]
    /// Minimum time working before the end of the turn is worth a notice.
    public var minimumWork: TimeInterval

    public init(minimumWork: TimeInterval = 45) { self.minimumWork = minimumWork }

    /// Statuses that mean "blocked on the person" rather than "done".
    public static func asksForInput(_ session: LiveAgentSession) -> Bool {
        if session.waitingFor?.isEmpty == false { return true }
        guard let status = session.status?.lowercased() else { return false }
        return ["wait", "permission", "input", "approval", "blocked"].contains { status.contains($0) }
    }

    /// Sessions started by a program (SDK, headless runs) have nobody waiting in front of them.
    public static func isAttended(_ session: LiveAgentSession) -> Bool {
        guard let entry = session.entrypoint?.lowercased() else { return true }
        return !entry.hasPrefix("sdk")
    }

    public mutating func update(_ sessions: [LiveAgentSession], now: Date = Date()) -> [AgentWaitEvent] {
        var events: [AgentWaitEvent] = []
        var next: [String: State] = [:]
        for session in sessions {
            var state = states[session.sessionID] ?? State()
            // First sight of a session: take note, never announce what happened before DevDeck looked.
            let known = states[session.sessionID] != nil
            if session.isBusy {
                if state.busySince == nil { state.busySince = known ? now : (session.updatedAt ?? now) }
            } else {
                if known, state.status == "busy", let since = state.busySince, Self.isAttended(session) {
                    let worked = now.timeIntervalSince(since)
                    let asks = Self.asksForInput(session)
                    if asks || worked >= minimumWork {
                        events.append(AgentWaitEvent(session: session, reason: asks ? .needsInput : .finished, worked: worked))
                    }
                }
                state.busySince = nil
            }
            state.status = session.status
            next[session.sessionID] = state
        }
        states = next
        return events
    }
}
