import Darwin
import Foundation

/// What game mode does while it is on. Everything here is the user's choice.
public struct GameSettings: Codable, Hashable, Sendable {
    /// When a game is detected: "ask" (recommend it), "auto" (turn it on), "off" (do not look).
    public var detect = "ask"
    /// Pause (not close) while playing; everything resumes when game mode ends.
    public var pauseHeadless = true
    public var pauseIdleAgents = false
    public var pauseServers = false
    public var pauseDocker = false
    /// Only critical alerts get through.
    public var quietAlerts = true
    public var hideIsland = true
    /// DevDeck itself samples less often and skips its background scans.
    public var lowPower = true
    /// Apps to treat as games even if they do not declare it (names as shown in the Dock).
    public var extraGames: [String] = []
    /// Apps never to treat as games.
    public var notGames: [String] = []
    /// Groups never to pause (group ids).
    public var neverPause: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        detect = try c.decodeIfPresent(String.self, forKey: .detect) ?? d.detect
        pauseHeadless = try c.decodeIfPresent(Bool.self, forKey: .pauseHeadless) ?? d.pauseHeadless
        pauseIdleAgents = try c.decodeIfPresent(Bool.self, forKey: .pauseIdleAgents) ?? d.pauseIdleAgents
        pauseServers = try c.decodeIfPresent(Bool.self, forKey: .pauseServers) ?? d.pauseServers
        pauseDocker = try c.decodeIfPresent(Bool.self, forKey: .pauseDocker) ?? d.pauseDocker
        quietAlerts = try c.decodeIfPresent(Bool.self, forKey: .quietAlerts) ?? d.quietAlerts
        hideIsland = try c.decodeIfPresent(Bool.self, forKey: .hideIsland) ?? d.hideIsland
        lowPower = try c.decodeIfPresent(Bool.self, forKey: .lowPower) ?? d.lowPower
        extraGames = try c.decodeIfPresent([String].self, forKey: .extraGames) ?? []
        notGames = try c.decodeIfPresent([String].self, forKey: .notGames) ?? []
        neverPause = try c.decodeIfPresent([String].self, forKey: .neverPause) ?? []
    }
}

public enum GameDetector {
    /// Folders that game stores install into.
    static let storeFolders = ["/steamapps/common/", "/Epic Games/", "/GOG Games/", "/Battle.net/", "/Riot Games/", "/CrossOver/Bottles/", "/Heroic/"]

    /// Does this running app look like a game? `category` is its `LSApplicationCategoryType`,
    /// `declaresGameMode` its `LSSupportsGameMode` / `GCSupportsGameMode` key.
    public static func looksLikeGame(name: String, category: String?, declaresGameMode: Bool, path: String, settings: GameSettings) -> Bool {
        let lower = name.lowercased()
        if settings.notGames.contains(where: { $0.lowercased() == lower }) { return false }
        if settings.extraGames.contains(where: { $0.lowercased() == lower }) { return true }
        if declaresGameMode { return true }
        if let category, category.contains("games") { return true }
        return storeFolders.contains { path.contains($0) }
    }
}

/// A process DevDeck paused, with its start time so a reused pid is never signalled by mistake.
public struct PausedProcess: Codable, Hashable, Sendable {
    public let pid: Int32
    public let start: Date
    public let group: String

    public init(pid: Int32, start: Date, group: String) {
        self.pid = pid; self.start = start; self.group = group
    }
}

public enum ProcessPauser {
    /// Which groups game mode would pause, given the settings. Never the system, DevDeck, or anything in `protected`.
    public static func groupsToPause(_ groups: [ProcessGroup], settings: GameSettings, protected: Set<Int32>) -> [ProcessGroup] {
        groups.filter { group in
            guard group.killable, !settings.neverPause.contains(group.id), group.pids.allSatisfy({ !protected.contains($0) }) else { return false }
            switch group.kind {
            case .headless: return settings.pauseHeadless
            case .docker: return settings.pauseDocker
            case .project: return settings.pauseServers && !group.services.isEmpty
            // An agent that is doing something is never paused.
            case .agent: return settings.pauseIdleAgents && group.cpuPercent < 3
            default: return false
            }
        }
    }

    /// Freezes the processes (SIGSTOP). They keep their memory and state and continue exactly where they were on `resume`.
    public static func pause(_ group: ProcessGroup, processes: [Int32: ProcessRecord]) -> [PausedProcess] {
        var paused: [PausedProcess] = []
        for pid in group.pids {
            guard let process = processes[pid], process.isMine, pid != getpid() else { continue }
            if kill(pid, SIGSTOP) == 0 { paused.append(PausedProcess(pid: pid, start: process.startTime, group: group.name)) }
        }
        return paused
    }

    /// Continues what was paused. `liveStarts` (pid → start time now) guards against pids that were reused meanwhile.
    @discardableResult
    public static func resume(_ paused: [PausedProcess], liveStarts: [Int32: Date]) -> Int {
        var count = 0
        for item in paused {
            if let live = liveStarts[item.pid], abs(live.timeIntervalSince(item.start)) > 2 { continue }
            if kill(item.pid, SIGCONT) == 0 { count += 1 }
        }
        return count
    }
}
