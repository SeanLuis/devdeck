import Foundation

/// Claude Code hands its status line the real limits of the account in use (`rate_limits`), from its own requests,
/// every time the line is drawn. DevDeck puts a small relay in front of the status line: it keeps those figures in
/// DevDeck's folder and then runs the status line the person already had, so nothing changes on screen.
/// This costs no request: Anthropic's usage endpoint allows each account only about 30 readings an hour.
public enum ClaudeStatusLine {
    static let suffix = " statusline --devdeck"

    public static func command(binary: String) -> String { "\"\(binary)\"" + suffix }
    public static func isOurs(_ command: String?) -> Bool { command?.hasSuffix(suffix) ?? false }

    public struct Limits: Codable, Equatable, Sendable {
        public struct Window: Codable, Equatable, Sendable {
            public var percent: Double
            public var resetsAt: Date?
        }
        /// Who Claude Code was logged in as when it drew the line.
        public var email: String?
        public var fiveHour: Window?
        public var sevenDay: Window?
        public var at: Date

        /// The figures as usage windows, named like the ones read from the endpoint.
        public var windows: [AccountUsage.Window] {
            [("5 h", fiveHour), ("7 días", sevenDay)].compactMap { name, window in
                window.map { AccountUsage.Window(name: name, percent: $0.percent, resetsAt: $0.resetsAt) }
            }
        }
    }

    public static func limitsFile(directory: URL) -> URL { directory.appendingPathComponent("claude-limits.json") }
    static func originalFile(directory: URL) -> URL { directory.appendingPathComponent("statusline-original.json") }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// What the status line receives on stdin → the limits worth keeping, or nil when it carries none.
    public static func parse(_ input: Data, email: String?, now: Date = Date()) -> Limits? {
        guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Limits.Window? {
            guard let value = limits[key] as? [String: Any],
                  let percent = ((value["used_percentage"] ?? value["utilization"]) as? NSNumber)?.doubleValue else { return nil }
            return .init(percent: percent, resetsAt: date(value["resets_at"]))
        }
        let result = Limits(email: email, fiveHour: window("five_hour"), sevenDay: window("seven_day"), at: now)
        return result.fiveHour == nil && result.sevenDay == nil ? nil : result
    }

    /// Every recent reading the relay kept, newest last. Each open session draws its own line with the figures of
    /// the replies it got, so they can belong to different accounts: one opened before a switch keeps showing the
    /// previous account's figures under the new account's email. `attribute` sorts them out.
    public static func readAll(directory: URL) -> [Limits] {
        guard let data = try? Data(contentsOf: limitsFile(directory: directory)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let list = try? decoder.decode([Limits].self, from: data) { return list }
        return (try? decoder.decode(Limits.self, from: data)).map { [$0] } ?? []
    }

    public static func read(directory: URL) -> Limits? { readAll(directory: directory).max { $0.at < $1.at } }

    /// Readings older than this are dropped from the file.
    static let keep: TimeInterval = 3600

    /// Two reset times that name the same window (the endpoint says 21:59:59 where the line says 22:00:00).
    static func sameReset(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 300
    }

    /// Adds a reading. One per window pair: a reading of the same windows replaces the older one, keeping the higher
    /// figure (use inside a window only goes up; a lower one comes from a session that has not had a reply for a while).
    static func merged(_ list: [Limits], adding new: Limits) -> [Limits] {
        var out = list.filter { new.at.timeIntervalSince($0.at) < keep }
        if let index = out.firstIndex(where: { sameReset($0.sevenDay?.resetsAt, new.sevenDay?.resetsAt) && sameReset($0.fiveHour?.resetsAt, new.fiveHour?.resetsAt) }) {
            let old = out.remove(at: index)
            var next = new
            if let a = old.fiveHour, let b = new.fiveHour, a.percent > b.percent { next.fiveHour = a }
            if let a = old.sevenDay, let b = new.sevenDay, a.percent > b.percent { next.sevenDay = a }
            out.append(next)
        } else {
            out.append(new)
        }
        return Array(out.suffix(24))
    }

    /// The figures that belong to one account, from every reading kept. The email a reading carries is only who was
    /// logged in when the line was drawn, not whose figures they are, so the weekly window's reset time decides:
    /// each account's week resets at its own hour. `known` is the reset this account's last reading gave;
    /// `others` the ones of every other account. nil when no recent reading is this account's.
    public static func attribute(_ readings: [Limits], email: String, known: Date?, others: [Date], now: Date = Date(),
                                 fresh: TimeInterval = 600) -> Limits? {
        let recent = readings.filter { now.timeIntervalSince($0.at) < fresh }
        let sameEmail = { (r: Limits) in r.email?.caseInsensitiveCompare(email) == .orderedSame }
        let claimedByOther = { (r: Limits) in others.contains { sameReset($0, r.sevenDay?.resetsAt) } }
        let mine: [Limits]
        if let known, known > now {
            // The week this account is in: readings with that reset. If another account's week ends at the same hour
            // the reset alone cannot tell them apart, and the email has to agree too.
            let ambiguous = others.contains { sameReset($0, known) }
            mine = recent.filter { sameReset($0.sevenDay?.resetsAt, known) && (!ambiguous || sameEmail($0)) }
        } else {
            // No week known yet (or it just reset): the email, as long as the week is not another account's.
            mine = recent.filter { sameEmail($0) && !claimedByOther($0) }
        }
        guard let newest = mine.max(by: { $0.at < $1.at }) else { return nil }
        func best(_ pick: (Limits) -> Limits.Window?) -> Limits.Window? {
            // The newest window that has not reset, and within it the highest figure.
            let live = mine.compactMap(pick).filter { ($0.resetsAt ?? .distantFuture) > now }
            guard let latest = live.compactMap(\.resetsAt).max() else { return live.max { $0.percent < $1.percent } }
            return live.filter { sameReset($0.resetsAt, latest) }.max { $0.percent < $1.percent }
        }
        return Limits(email: email, fiveHour: best(\.fiveHour), sevenDay: best(\.sevenDay), at: newest.at)
    }

    /// The email in Claude Code's config, reading only its account block (the file is large).
    static func liveEmail(home: String) -> String? {
        for path in [home + "/.claude/.config.json", home + "/.claude.json"] {
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { continue }
            let bytes = [UInt8](data)
            guard let range = JSONSplice.valueRange(of: "oauthAccount", in: bytes),
                  let block = try? JSONSerialization.jsonObject(with: Data(bytes[range])) as? [String: Any] else { return nil }
            return block["emailAddress"] as? String
        }
        return nil
    }

    /// Run by Claude Code each time it draws the line: keep the limits, then hand the line to the original command.
    public static func relay(input: Data, directory: URL, home: String = NSHomeDirectory()) -> Data {
        if let limits = parse(input, email: liveEmail(home: home)) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(merged(readAll(directory: directory), adding: limits)) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: limitsFile(directory: directory), options: .atomic)
            }
        }
        guard let command = originalCommand(directory: directory) else { return Data() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        do { try process.run() } catch { return Data() }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }

    /// The status line the person had before the relay, as Claude Code's settings held it.
    static func original(directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: originalFile(directory: directory)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func originalCommand(directory: URL) -> String? {
        guard let command = original(directory: directory)?["command"] as? String, !isOurs(command), !command.isEmpty else { return nil }
        return command
    }

    public static func installedCommand(home: String = NSHomeDirectory()) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ClaudeHooks.settingsPath(home: home))),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = (root["statusLine"] as? [String: Any])?["command"] as? String, isOurs(command) else { return nil }
        return command
    }

    /// Puts the relay in front of the status line (`command`), or takes it away and gives back the original (nil).
    /// Only the `statusLine` value of Claude Code's settings changes; a copy of the file is kept the first time.
    public static func apply(command: String?, directory: URL, home: String = NSHomeDirectory()) throws {
        let path = ClaudeHooks.settingsPath(home: home)
        let url = URL(fileURLWithPath: path)
        let existing = try? Data(contentsOf: url)
        if existing == nil, command == nil { return }
        let document = existing ?? Data("{}".utf8)
        guard var root = try? JSONSerialization.jsonObject(with: document) as? [String: Any] else { throw ClaudeHooks.HookError.unreadable }
        let current = root["statusLine"] as? [String: Any]
        let currentIsOurs = isOurs(current?["command"] as? String)
        var next: [String: Any]?
        if let command {
            if !currentIsOurs {
                // Remember what was there, even "nothing", so turning the relay off gives it back exactly.
                let saved = try JSONSerialization.data(withJSONObject: current ?? [:], options: [.withoutEscapingSlashes])
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try saved.write(to: originalFile(directory: directory), options: .atomic)
            }
            var line = current ?? [:]
            line["type"] = "command"
            line["command"] = command
            next = line
        } else {
            guard currentIsOurs else { return }
            let original = original(directory: directory) ?? [:]
            next = original.isEmpty ? nil : original
        }
        let updated: Data?
        if let next {
            let value = try JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            updated = JSONSplice.setting("statusLine", to: String(decoding: value, as: UTF8.self), in: document)
        } else {
            root["statusLine"] = nil
            updated = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        }
        guard let updated else { throw ClaudeHooks.HookError.unreadable }
        let backup = path + ".devdeck-backup"
        if let existing, !FileManager.default.fileExists(atPath: backup) { try? existing.write(to: URL(fileURLWithPath: backup)) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try updated.write(to: url, options: .atomic)
        if command == nil { try? FileManager.default.removeItem(at: originalFile(directory: directory)) }
    }
}
