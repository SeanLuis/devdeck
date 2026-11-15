import Foundation

/// A past conversation with a coding agent, as its transcript on disk describes it.
public struct SessionEntry: Identifiable, Hashable, Sendable {
    public var id: String { file }
    public let agent: String
    public let file: String
    /// The id the agent resumes it by.
    public let sessionID: String
    /// Folder it worked in.
    public var project: String
    /// Folder it was last working in, when it moved from where it started.
    public var workFolder: String?
    public var branch: String?
    /// The agent's own title, or the first thing that was asked.
    public var title: String
    public let modified: Date
    public let sizeBytes: UInt64

    public init(agent: String, file: String, sessionID: String, project: String, branch: String? = nil, title: String, modified: Date, sizeBytes: UInt64) {
        self.agent = agent; self.file = file; self.sessionID = sessionID; self.project = project; self.branch = branch
        self.title = title; self.modified = modified; self.sizeBytes = sizeBytes
    }

    /// What to type to open it again.
    /// Where its work happened: the folder it ended up in.
    public var folder: String { workFolder ?? project }

    public var resumeArguments: [String] {
        agent == "Codex" ? ["resume", sessionID] : ["--resume", sessionID]
    }
}

/// A place in a transcript where the searched text was said.
public struct SessionHit: Identifiable, Hashable, Sendable {
    public var id: String { entry.id }
    public let entry: SessionEntry
    /// The words around the first match.
    public let snippet: String
    /// True when the person said it, false when the agent did.
    public let fromUser: Bool
    /// Matching messages found in this session (capped).
    public let count: Int
}

/// Every session the agents keep on this Mac, with search over what was said. Reads only; nothing is sent anywhere.
public enum SessionLibrary {
    static let headBytes = 256 << 10
    static let tailBytes = 96 << 10
    /// A line longer than this is a pasted file or a tool dump, not something a person searches for.
    static let longestLine = 4 << 20
    static let hitsPerSession = 20

    // MARK: Listing

    /// All sessions, newest first. `known` lets unchanged files skip the read.
    public static func list(home: String = NSHomeDirectory(), known: [String: SessionEntry] = [:]) -> [SessionEntry] {
        var out: [SessionEntry] = []
        let fm = FileManager.default
        func attributes(_ path: String) -> (Date, UInt64)? {
            guard let a = try? fm.attributesOfItem(atPath: path), let modified = a[.modificationDate] as? Date else { return nil }
            return (modified, (a[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        func add(_ path: String, _ read: (String, Date, UInt64) -> SessionEntry?) {
            guard let (modified, size) = attributes(path), size > 0 else { return }
            if let old = known[path], old.modified == modified, old.sizeBytes == size { out.append(old); return }
            if let entry = read(path, modified, size) { out.append(entry) }
        }
        // Claude Code: one folder per project, one file per session; subagents live deeper and are skipped.
        let claude = home + "/.claude/projects"
        for folder in (try? fm.contentsOfDirectory(atPath: claude)) ?? [] {
            for name in (try? fm.contentsOfDirectory(atPath: claude + "/" + folder)) ?? [] where name.hasSuffix(".jsonl") {
                add(claude + "/" + folder + "/" + name, describeClaude)
            }
        }
        let codex = home + "/.codex/sessions"
        if let walker = fm.enumerator(atPath: codex) {
            for case let name as String in walker where name.hasSuffix(".jsonl") { add(codex + "/" + name, describeCodex) }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    private static func lines(of path: String, head: Bool, bytes: Int) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [] }
        defer { try? handle.close() }
        var cut = false
        if !head {
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
            try? handle.seek(toOffset: start)
            cut = start > 0
        }
        guard let data = try? handle.read(upToCount: bytes), !data.isEmpty else { return [] }
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        if cut, !parts.isEmpty { parts.removeFirst() }
        if head, data.count == bytes, !parts.isEmpty { parts.removeLast() }   // last line cut short
        return parts
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Text a person typed, without the wrappers the tools add around commands and context.
    static func plainPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Caveat:"), !trimmed.hasPrefix("[Request interrupted") else { return nil }
        return trimmed
    }

    static func oneLine(_ text: String, limit: Int = 120) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// The readable text of a Claude Code transcript line, when it is something a person or the agent said.
    static func claudeText(_ obj: [String: Any]) -> (text: String, fromUser: Bool)? {
        guard let type = obj["type"] as? String, type == "user" || type == "assistant", (obj["isMeta"] as? Bool) != true,
              let message = obj["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return (text, type == "user") }
        let blocks = (message["content"] as? [[String: Any]]) ?? []
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return text.isEmpty ? nil : (text, type == "user")
    }

    static func codexText(_ obj: [String: Any]) -> (text: String, fromUser: Bool)? {
        // Current logs wrap each item in a payload; older ones are the item itself.
        let item = (obj["payload"] as? [String: Any]) ?? obj
        guard (item["type"] as? String) == "message", let role = item["role"] as? String, role == "user" || role == "assistant" else { return nil }
        let blocks = (item["content"] as? [[String: Any]]) ?? []
        let text = blocks.compactMap { $0["text"] as? String }.filter { plainPrompt($0) != nil }.joined(separator: "\n")
        return text.isEmpty ? nil : (text, role == "user")
    }

    static func describeClaude(_ path: String, modified: Date, size: UInt64) -> SessionEntry? {
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var project = "", branch: String?, title: String?, prompt: String?
        for line in lines(of: path, head: true, bytes: headBytes) {
            guard let obj = object(line) else { continue }
            if project.isEmpty, let cwd = obj["cwd"] as? String { project = cwd; branch = obj["gitBranch"] as? String }
            if title == nil, (obj["type"] as? String) == "ai-title" { title = obj["aiTitle"] as? String }
            if prompt == nil, (obj["isSidechain"] as? Bool) != true, let said = claudeText(obj), said.fromUser { prompt = plainPrompt(said.text) }
            if !project.isEmpty, prompt != nil, title != nil { break }
        }
        var workFolder: String?
        if size > UInt64(headBytes) {
            var newTitle = false, newPlace = false
            for line in lines(of: path, head: false, bytes: tailBytes).reversed() {
                guard let obj = object(line) else { continue }
                if !newTitle, (obj["type"] as? String) == "ai-title", let newer = obj["aiTitle"] as? String { title = newer; newTitle = true }
                if !newPlace, let cwd = obj["cwd"] as? String {
                    newPlace = true
                    if cwd != project { workFolder = cwd }
                    if let newer = obj["gitBranch"] as? String, !newer.isEmpty { branch = newer }
                }
                if newTitle, newPlace { break }
            }
        }
        // A file with nobody speaking in it is bookkeeping, not a conversation.
        guard !project.isEmpty, let shown = title ?? prompt else { return nil }
        var entry = SessionEntry(agent: "Claude Code", file: path, sessionID: id, project: project, branch: branch?.isEmpty == false ? branch : nil,
                                 title: oneLine(shown), modified: modified, sizeBytes: size)
        entry.workFolder = workFolder
        return entry
    }

    static func describeCodex(_ path: String, modified: Date, size: UInt64) -> SessionEntry? {
        var id: String?, project = "", prompt: String?
        for line in lines(of: path, head: true, bytes: headBytes) {
            guard let obj = object(line) else { continue }
            let payload = obj["payload"] as? [String: Any]
            if (obj["type"] as? String) == "session_meta" {
                id = (payload?["id"] as? String) ?? (payload?["session_id"] as? String)
                project = (payload?["cwd"] as? String) ?? project
            } else if id == nil, payload == nil, let old = obj["id"] as? String, obj["timestamp"] != nil {
                id = old
            }
            if project.isEmpty, let cwd = payload?["cwd"] as? String { project = cwd }
            if prompt == nil, let said = codexText(obj), said.fromUser { prompt = plainPrompt(said.text) }
            if id != nil, prompt != nil, !project.isEmpty { break }
        }
        guard let id, let prompt else { return nil }
        return SessionEntry(agent: "Codex", file: path, sessionID: id, project: project, title: oneLine(prompt), modified: modified, sizeBytes: size)
    }

    // MARK: Search

    /// Bytes to look for: the query as it sits inside a JSON string, lowercased where it is plain ASCII.
    static func needle(_ query: String) -> [UInt8] {
        var out: [UInt8] = []
        for byte in query.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            if byte == 0x22 || byte == 0x5C { out.append(0x5C) }   // " and \ are escaped in the file
            out.append(byte >= 0x41 && byte <= 0x5A ? byte + 32 : byte)
        }
        return out
    }

    /// Offsets of `needle` in `bytes`, ignoring ASCII case (Horspool). `needle` must already be lowercased.
    static func find(_ needle: [UInt8], in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        let m = needle.count, n = bytes.count
        guard m > 0, n - start >= m else { return nil }
        var skip = [Int](repeating: m, count: 256)
        for i in 0..<(m - 1) {
            skip[Int(needle[i])] = m - 1 - i
            if needle[i] >= 0x61 && needle[i] <= 0x7A { skip[Int(needle[i] - 32)] = m - 1 - i }
        }
        @inline(__always) func fold(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 32 : b }
        var i = start
        return needle.withUnsafeBufferPointer { pattern in
            while i <= n - m {
                let last = bytes[i + m - 1]
                if fold(last) == pattern[m - 1] {
                    var j = m - 2
                    while j >= 0, fold(bytes[i + j]) == pattern[j] { j -= 1 }
                    if j < 0 { return i }
                }
                i += skip[Int(last)]
            }
            return nil
        }
    }

    /// The words around the first place `query` appears in `text`.
    static func snippet(_ text: String, query: String, around: Int = 70) -> String? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) ?? text.range(of: query, options: .caseInsensitive) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -around, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: around, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    /// Looks for `query` in what was said in one session.
    public static func search(_ query: String, in entry: SessionEntry) -> SessionHit? {
        let pattern = needle(query)
        let plain = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.count >= 2, let data = try? Data(contentsOf: URL(fileURLWithPath: entry.file), options: .alwaysMapped) else { return nil }
        let codex = entry.agent == "Codex"
        var first: (String, Bool)?
        var count = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var position = 0
            while count < hitsPerSession, let at = find(pattern, in: bytes, from: position) {
                var lineStart = at
                while lineStart > 0, bytes[lineStart - 1] != 0x0A, at - lineStart <= longestLine { lineStart -= 1 }
                var lineEnd = at
                while lineEnd < bytes.count, bytes[lineEnd] != 0x0A, lineEnd - lineStart <= longestLine { lineEnd += 1 }
                position = max(lineEnd, at + pattern.count)
                guard lineEnd - lineStart <= longestLine else {
                    // Skip the rest of an oversized line without parsing it.
                    while position < bytes.count, bytes[position] != 0x0A { position += 1 }
                    continue
                }
                // Claude Code writes what was said as lines that begin with "parentUuid"; its other lines repeat it for the API.
                if !codex {
                    let marker: [UInt8] = Array("{\"parentUuid\"".utf8)
                    guard lineEnd - lineStart > marker.count, (0..<marker.count).allSatisfy({ bytes[lineStart + $0] == marker[$0] }) else { continue }
                }
                let line = Data(bytes: bytes.baseAddress! + lineStart, count: lineEnd - lineStart)
                guard let obj = object(line), let said = codex ? codexText(obj) : claudeText(obj),
                      let around = snippet(said.text, query: plain) else { continue }
                count += 1
                if first == nil { first = (around, said.fromUser) }
            }
        }
        guard let first else { return nil }
        return SessionHit(entry: entry, snippet: first.0, fromUser: first.1, count: count)
    }

    // MARK: Resume

    /// A script Terminal can open: goes to the session's folder and opens it again with its own agent.
    public static func resumeScript(_ entry: SessionEntry, binaryPath: String) -> String {
        launchScript(folder: entry.project, binaryPath: binaryPath, arguments: entry.resumeArguments)
    }

    /// A script Terminal can open: goes to a folder and starts an agent there.
    public static func launchScript(folder: String, binaryPath: String, arguments: [String] = []) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = ([binaryPath] + arguments).map(quoted).joined(separator: " ")
        return """
        #!/bin/zsh -l
        cd \(folder.isEmpty ? "~" : quoted(folder)) || exit 1
        clear
        exec \(command)

        """
    }
}
