import Foundation

/// Something an agent started and left running after it was gone: its parent is no longer there
/// (the process now hangs from launchd), so nothing will ever close it.
public struct AgentLeftover: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// A tool server (MCP) whose agent exited.
        case toolServer
        /// A windowless browser nobody is driving any more.
        case headlessBrowser
        /// A command an agent ran in its shell (a dev server, a watcher, a test run).
        case command
    }

    public var id: Int32 { rootPid }
    public let kind: Kind
    public let rootPid: Int32
    /// The root and everything under it.
    public let pids: [Int32]
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let command: String
    public let cwd: String?
    public let since: Date
    /// Ports it listens on: a server somebody may still be using.
    public var ports: [UInt16] = []
}

public enum AgentLeftovers {
    /// Younger than this, the parent may simply be restarting.
    public static let minimumAge: TimeInterval = 600

    /// Claude Code runs every shell command through a snapshot of the user's shell; Codex and others leave similar marks.
    static func isAgentShell(_ args: [String]) -> Bool {
        let joined = args.joined(separator: " ")
        return joined.contains("/.claude/shell-snapshots/") || joined.contains("/.codex/shell_snapshots/")
    }

    public static func find(processes: [Int32: ProcessRecord], listening: [Int32: [UInt16]] = [:], ownPid: Int32 = getpid(),
                            now: Date = Date()) -> [AgentLeftover] {
        let children = ProcessTreeLoad.childrenIndex(processes)
        var out: [AgentLeftover] = []
        for process in processes.values where process.isMine && process.ppid == 1 && process.pid != ownPid {
            guard now.timeIntervalSince(process.startTime) >= minimumAge else { continue }
            let exe = process.executablePath
            let kind: AgentLeftover.Kind
            if Classifier.isHeadlessBrowser(exe: exe, args: process.args) { kind = .headlessBrowser }
            else if isAgentShell(process.args) { kind = .command }
            else if Classifier.isMCPServer(process.args), Classifier.appBundleName(exe) == nil { kind = .toolServer }
            else { continue }

            var pids: [Int32] = []
            var memory: UInt64 = 0
            var cpu = 0.0
            var ports: [UInt16] = []
            var queue = [process.pid]
            var seen = Set<Int32>()
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted, let p = processes[pid] else { continue }
                pids.append(pid)
                memory += p.memoryBytes
                cpu += p.cpuPercent
                ports += listening[pid] ?? []
                queue += children[pid] ?? []
            }
            // The interesting command is what the shell runs, not the shell wrapper itself.
            var shown = process
            if kind == .command, let child = (children[process.pid] ?? []).compactMap({ processes[$0] }).max(by: { $0.memoryBytes < $1.memoryBytes }) {
                shown = child
            }
            out.append(AgentLeftover(kind: kind, rootPid: process.pid, pids: pids, memoryBytes: memory, cpuPercent: cpu,
                                     command: Fmt.shortCommand(shown.args.isEmpty ? [shown.name] : shown.args, max: 6),
                                     cwd: shown.cwd ?? process.cwd, since: process.startTime, ports: Array(Set(ports)).sorted()))
        }
        return out.sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
