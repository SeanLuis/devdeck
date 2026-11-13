import CryptoKit
import Foundation
import SQLite3

/// Usage of one agent that does not write JSONL transcripts, kept between scans so only new data is read.
struct ExternalUsage {
    var buckets: [UsageKey: TokenCount] = [:]
    var hours: [Int: TokenCount] = [:]
    var sessions: [String: AgentSession] = [:]
    /// What the source looked like at the last read (modification dates), to skip unchanged data.
    var stamp = ""
    /// Last row already counted (append-only databases).
    var lastRow: Int64 = 0
    /// Per-file state for sources made of many small files.
    var files: [String: (stamp: String, usage: [UsageEvent])] = [:]

    mutating func add(_ event: UsageEvent) {
        let key = UsageKey(agent: event.agent, day: AgentUsageReport.dayString(event.time), model: event.model, project: event.project)
        buckets[key] = (buckets[key] ?? TokenCount()) + event.tokens
        let hour = Int(event.time.timeIntervalSince1970 / 3600)
        hours[hour] = (hours[hour] ?? TokenCount()) + event.tokens
        let id = event.agent + "|" + event.session
        let previous = sessions[id]
        sessions[id] = AgentSession(agent: event.agent, file: event.file, project: event.project,
                                    lastActivity: max(previous?.lastActivity ?? .distantPast, event.time),
                                    tokens: (previous?.tokens ?? TokenCount()) + event.tokens, model: event.model, sizeBytes: 0,
                                    sessionID: event.session, parentID: event.parent, title: event.title ?? previous?.title)
    }

    mutating func reset() {
        buckets = [:]; hours = [:]; sessions = [:]; lastRow = 0
    }
}

struct UsageEvent {
    let agent: String
    let session: String
    var parent: String?
    var title: String?
    let project: String
    let model: String
    let time: Date
    let tokens: TokenCount
    let file: String
}

/// Read-only SQLite access, just enough for the agents' local databases.
final class SQLiteReader {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1500)
    }

    deinit { sqlite3_close(db) }

    enum Value {
        case int(Int64), text(String)
    }

    /// Runs `sql` and calls `row` with a column reader for each result row. Returns false if the query failed.
    @discardableResult
    func query(_ sql: String, _ bindings: [Value] = [], row: (Row) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            switch value {
            case .int(let v): sqlite3_bind_int64(statement, Int32(index + 1), v)
            case .text(let v): sqlite3_bind_text(statement, Int32(index + 1), v, -1, transient)
            }
        }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW { row(Row(statement: statement)) } else { return code == SQLITE_DONE }
        }
    }

    struct Row {
        let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    }
}

enum ExternalSource: String, CaseIterable {
    case openCode, devin, gemini

    var agent: String {
        switch self {
        case .openCode: return "OpenCode"
        case .devin: return "Devin"
        case .gemini: return "Gemini CLI"
        }
    }

    private static func stamp(_ paths: [String]) -> String {
        paths.map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(Int(modified))-\((attributes?[.size] as? NSNumber)?.intValue ?? 0)"
        }.joined(separator: "|")
    }

    private static func date(_ raw: Int64) -> Date {
        // Seconds or milliseconds since 1970, depending on the tool.
        Date(timeIntervalSince1970: raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw))
    }

    func refresh(_ usage: inout ExternalUsage, home: String, since: Date, projectCandidates: Set<String>) {
        switch self {
        case .openCode: Self.readOpenCode(&usage, db: home + "/.local/share/opencode/opencode.db", since: since)
        case .devin: Self.readDevin(&usage, db: home + "/.local/share/devin/cli/sessions.db", since: since)
        case .gemini: Self.readGemini(&usage, root: home + "/.gemini/tmp", since: since, projectCandidates: projectCandidates)
        }
    }

    // MARK: OpenCode — SQLite, one JSON document per message

    /// Small database: the whole window is read again whenever the file changes.
    static func readOpenCode(_ usage: inout ExternalUsage, db path: String, since: Date) {
        let stamp = stamp([path, path + "-wal"])
        guard stamp != usage.stamp else { return }
        guard let db = SQLiteReader(path: path) else { return }
        var fresh = ExternalUsage()
        let sql = """
        select m.session_id, m.time_created,
               json_extract(m.data,'$.tokens.input'), json_extract(m.data,'$.tokens.output'), json_extract(m.data,'$.tokens.reasoning'),
               json_extract(m.data,'$.tokens.cache.read'), json_extract(m.data,'$.tokens.cache.write'),
               json_extract(m.data,'$.modelID'), coalesce(json_extract(m.data,'$.path.cwd'), s.directory), s.parent_id, s.title
        from message m join session s on s.id = m.session_id
        where m.time_created >= ?1 and json_extract(m.data,'$.role') = 'assistant'
        """
        let ok = db.query(sql, [.int(Int64(since.timeIntervalSince1970 * 1000))]) { row in
            var tokens = TokenCount()
            tokens.input = UInt64(max(0, row.int(2)))
            tokens.output = UInt64(max(0, row.int(3) + row.int(4)))
            tokens.cacheRead = UInt64(max(0, row.int(5)))
            tokens.cacheWrite = UInt64(max(0, row.int(6)))
            guard tokens.total > 0 else { return }
            tokens.messages = 1
            fresh.add(UsageEvent(agent: "OpenCode", session: row.text(0), parent: row.isNull(9) ? nil : row.text(9),
                                 title: row.isNull(10) ? nil : row.text(10), project: row.text(8),
                                 model: row.isNull(7) ? "opencode" : row.text(7), time: date(row.int(1)), tokens: tokens, file: path))
        }
        guard ok else { return }
        fresh.stamp = stamp
        usage = fresh
    }

    // MARK: Devin — SQLite, append-only message nodes

    /// Big database (gigabytes): only rows after the last one seen are read; the first read starts at the window.
    static func readDevin(_ usage: inout ExternalUsage, db path: String, since: Date) {
        let stamp = stamp([path, path + "-wal"])
        guard stamp != usage.stamp else { return }
        guard let db = SQLiteReader(path: path) else { return }
        if usage.lastRow == 0 {
            usage.reset()
            usage.lastRow = firstRow(db, since: since)
        }
        var last = usage.lastRow
        var events: [UsageEvent] = []
        let sql = """
        select m.row_id, m.session_id, m.created_at,
               json_extract(m.chat_message,'$.metadata.metrics.input_tokens'), json_extract(m.chat_message,'$.metadata.metrics.output_tokens'),
               json_extract(m.chat_message,'$.metadata.metrics.cache_read_tokens'), json_extract(m.chat_message,'$.metadata.metrics.cache_creation_tokens'),
               s.working_directory, s.model, s.title
        from message_nodes m join sessions s on s.id = m.session_id
        where m.row_id > ?1 and json_extract(m.chat_message,'$.role') = 'assistant'
        order by m.row_id
        """
        let ok = db.query(sql, [.int(usage.lastRow)]) { row in
            last = max(last, row.int(0))
            var tokens = TokenCount()
            tokens.input = UInt64(max(0, row.int(3)))
            tokens.output = UInt64(max(0, row.int(4)))
            tokens.cacheRead = UInt64(max(0, row.int(5)))
            tokens.cacheWrite = UInt64(max(0, row.int(6)))
            guard tokens.total > 0 else { return }
            tokens.messages = 1
            events.append(UsageEvent(agent: "Devin", session: row.text(1), title: row.isNull(9) ? nil : row.text(9), project: row.text(7),
                                     model: row.text(8).isEmpty ? "devin" : row.text(8), time: date(row.int(2)), tokens: tokens, file: path))
        }
        guard ok else { return }
        for event in events { usage.add(event) }
        // Rows that are not assistant messages also advance the cursor, so they are never parsed twice.
        db.query("select max(row_id) from message_nodes") { last = max(last, $0.int(0)) }
        usage.lastRow = last
        usage.stamp = stamp
    }

    /// First row inside the window. Rows are appended in time order, so a binary search on the row id
    /// avoids walking gigabytes of old messages.
    private static func firstRow(_ db: SQLiteReader, since: Date) -> Int64 {
        var low: Int64 = 0, high: Int64 = 0
        db.query("select min(row_id), max(row_id) from message_nodes") { low = $0.int(0); high = $0.int(1) }
        guard high > 0 else { return 0 }
        var sample: Int64 = 0
        db.query("select created_at from message_nodes where row_id = ?1", [.int(high)]) { sample = $0.int(0) }
        let cutoff = Int64(sample > 100_000_000_000 ? since.timeIntervalSince1970 * 1000 : since.timeIntervalSince1970)
        while low < high {
            let mid = (low + high) / 2
            var created: Int64 = 0
            // Row ids can have gaps: take the first existing row at or after `mid`.
            db.query("select created_at from message_nodes where row_id >= ?1 order by row_id limit 1", [.int(mid)]) { created = $0.int(0) }
            if created < cutoff { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    // MARK: Gemini CLI — one JSON file per chat under ~/.gemini/tmp/<hash of the folder>/chats

    static func readGemini(_ usage: inout ExternalUsage, root: String, since: Date, projectCandidates: Set<String>) {
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        var folders: [String: String] = [:]
        for candidate in projectCandidates {
            let hash = SHA256.hash(data: Data(candidate.utf8)).map { String(format: "%02x", $0) }.joined()
            folders[hash] = candidate
        }
        var seen = Set<String>()
        var changed = false
        for project in projects {
            let chats = "\(root)/\(project)/chats"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: chats)) ?? [] where name.hasSuffix(".json") {
                let path = "\(chats)/\(name)"
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, modified >= since else { continue }
                seen.insert(path)
                let stamp = stamp([path])
                if usage.files[path]?.stamp == stamp { continue }
                changed = true
                usage.files[path] = (stamp, geminiEvents(path: path, project: folders[project] ?? project, fallback: modified))
            }
        }
        for path in usage.files.keys where !seen.contains(path) { usage.files[path] = nil; changed = true }
        guard changed else { return }
        let files = usage.files
        usage.reset()
        for (_, entry) in files { for event in entry.usage where event.time >= since { usage.add(event) } }
    }

    static func geminiEvents(path: String, project: String, fallback: Date) -> [UsageEvent] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count < 64 << 20,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return [] }
        let session = (root["sessionId"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return messages.compactMap { message in
            guard let usage = message["tokens"] as? [String: Any] else { return nil }
            func number(_ key: String) -> UInt64 { UInt64(max(0, (usage[key] as? NSNumber)?.intValue ?? 0)) }
            var tokens = TokenCount()
            let cached = number("cached")
            tokens.input = number("input") > cached ? number("input") - cached : 0
            tokens.cacheRead = cached
            tokens.output = number("output") + number("thoughts")
            guard tokens.total > 0 else { return nil }
            tokens.messages = 1
            let time = (message["timestamp"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? fallback
            return UsageEvent(agent: "Gemini CLI", session: session, project: project, model: (message["model"] as? String) ?? "gemini",
                              time: time, tokens: tokens, file: path)
        }
    }
}
