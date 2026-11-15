import Foundation

/// Something Claude Code told DevDeck through a hook, the moment it happened.
public struct AgentHookEvent: Codable, Hashable, Sendable {
    /// "Notification" | "Stop" | "UserPromptSubmit"
    public let event: String
    public let sessionID: String
    public let cwd: String
    /// What Claude Code says it needs ("Claude needs your permission to use Bash").
    public let message: String?
    /// "permission_prompt", "idle_prompt"… when Claude Code names the kind of notice.
    public let kind: String?
    public let at: Date

    public init(event: String, sessionID: String, cwd: String, message: String?, kind: String?, at: Date) {
        self.event = event; self.sessionID = sessionID; self.cwd = cwd; self.message = message; self.kind = kind; self.at = at
    }

    /// A notice that means "the agent is blocked until you answer".
    public var asksForInput: Bool {
        guard event == "Notification" else { return false }
        if let kind { return kind.contains("permission") || kind.contains("elicitation") }
        return message?.lowercased().contains("permission") ?? false
    }
}

/// Optional hooks in Claude Code's own settings, so DevDeck hears at once that a session stopped or asks for a
/// permission instead of noticing seconds later. Off unless the user turns it on; the hook only appends one line
/// to a file in DevDeck's folder and never answers Claude Code, so it cannot change what the agent does.
public enum ClaudeHooks {
    public static let events = ["Notification", "Stop", "UserPromptSubmit"]
    /// How DevDeck's own entries are told apart from everyone else's.
    static let suffix = " hook --devdeck"

    public static func command(binary: String) -> String { "\"\(binary)\"" + suffix }

    static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.hasSuffix(suffix) ?? false }
    }

    /// The command DevDeck has installed, if any.
    public static func installedCommand(in hooks: [String: Any]?) -> String? {
        for event in events {
            for entry in (hooks?[event] as? [[String: Any]]) ?? [] {
                for hook in (entry["hooks"] as? [[String: Any]]) ?? [] {
                    if let command = hook["command"] as? String, command.hasSuffix(suffix) { return command }
                }
            }
        }
        return nil
    }

    /// The `hooks` block without DevDeck's entries; everything else stays as it was.
    public static func removing(from hooks: [String: Any]?) -> [String: Any] {
        var out = hooks ?? [:]
        for (event, value) in out {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            if kept.count == entries.count { continue }
            out[event] = kept.isEmpty ? nil : kept
        }
        return out
    }

    /// The `hooks` block with DevDeck's entries (once each), after everyone else's.
    public static func adding(to hooks: [String: Any]?, command: String) -> [String: Any] {
        var out = removing(from: hooks)
        for event in events {
            var entries = (out[event] as? [[String: Any]]) ?? []
            entries.append(["hooks": [["type": "command", "command": command, "timeout": 5] as [String: Any]]])
            out[event] = entries
        }
        return out
    }

    public static func settingsPath(home: String = NSHomeDirectory()) -> String { home + "/.claude/settings.json" }

    public static func installedCommand(home: String = NSHomeDirectory()) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath(home: home))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return installedCommand(in: root["hooks"] as? [String: Any])
    }

    public enum HookError: LocalizedError {
        case unreadable
        public var errorDescription: String? { L("No se pudo leer la configuración de Claude Code; no se cambió nada.") }
    }

    /// Installs (`command`) or removes (nil) DevDeck's hooks. Only the `hooks` value is rewritten: the rest of the
    /// file is left byte for byte, and a copy of the file as it was is kept beside it the first time.
    public static func apply(command: String?, home: String = NSHomeDirectory()) throws {
        let path = settingsPath(home: home)
        let url = URL(fileURLWithPath: path)
        let existing = try? Data(contentsOf: url)
        if existing == nil, command == nil { return }
        let document = existing ?? Data("{}".utf8)
        guard let root = try? JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw HookError.unreadable }
        let current = root["hooks"] as? [String: Any]
        let next = command.map { adding(to: current, command: $0) } ?? removing(from: current)
        let value = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let updated = JSONSplice.setting("hooks", to: String(decoding: value, as: UTF8.self), in: document) else { throw HookError.unreadable }
        let backup = path + ".devdeck-backup"
        if let existing, !FileManager.default.fileExists(atPath: backup) { try? existing.write(to: URL(fileURLWithPath: backup)) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try updated.write(to: url, options: .atomic)
    }

    // MARK: Events

    public static func eventsFile(directory: URL) -> URL { directory.appendingPathComponent("agent-events.jsonl") }

    /// What a hook receives on stdin → the event to keep. nil for anything that is not one of ours.
    public static func parse(_ input: Data, now: Date = Date()) -> AgentHookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = obj["hook_event_name"] as? String, events.contains(event),
              let session = obj["session_id"] as? String else { return nil }
        let message = (obj["message"] as? String).map { String($0.prefix(300)) }
        return AgentHookEvent(event: event, sessionID: session, cwd: (obj["cwd"] as? String) ?? "", message: message,
                              kind: obj["notification_type"] as? String, at: now)
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    /// Called by the hook itself: one line appended, nothing printed.
    public static func record(_ input: Data, directory: URL) {
        guard let event = parse(input), var line = try? coder().0.encode(event) else { return }
        line.append(0x0A)
        let url = eventsFile(directory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Events written after `offset`, and where to read from next time. A file that shrank is read from the start.
    public static func read(directory: URL, from offset: UInt64) -> (events: [AgentHookEvent], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: eventsFile(directory: directory)) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset > size ? 0 : offset
        guard size > start else { return ([], size) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return ([], start) }
        // Only whole lines: a hook may be in the middle of writing one.
        guard let lastBreak = data.lastIndex(of: 0x0A) else { return ([], start) }
        let whole = data[data.startIndex...lastBreak]
        let decoder = coder().1
        let events = whole.split(separator: 0x0A).compactMap { try? decoder.decode(AgentHookEvent.self, from: Data($0)) }
        return (events, start + UInt64(whole.count))
    }

    /// Keeps the events file from growing for ever; called when the app starts.
    public static func trim(directory: URL, above bytes: UInt64 = 1 << 20) {
        let url = eventsFile(directory: directory)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size > bytes { try? Data().write(to: url) }
    }
}
