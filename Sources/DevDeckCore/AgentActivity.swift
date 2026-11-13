import Foundation

/// The last thing an agent did, read from the end of its transcript: the tool it called or what it wrote.
public struct AgentActivity: Hashable, Sendable {
    /// Tool name ("Bash", "Edit"…); nil when the last step was plain text.
    public let tool: String?
    public let detail: String
    public let at: Date?

    public init(tool: String?, detail: String, at: Date?) {
        self.tool = tool; self.detail = detail; self.at = at
    }

    public var summary: String {
        guard let tool else { return detail }
        return detail.isEmpty ? tool : "\(tool) · \(detail)"
    }
}

public enum AgentActivityReader {
    /// Only the end of the file is read: transcripts grow to hundreds of megabytes.
    static let tailBytes: UInt64 = 128 << 10

    public static func claude(transcript path: String) -> AgentActivity? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // cut in the middle of a line
        for line in lines.reversed() {
            if let activity = parseClaude(line: Data(line)) { return activity }
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One transcript line → activity, when it is an assistant step with something to show.
    public static func parseClaude(line: Data) -> AgentActivity? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return nil }
        let at = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) }
        for block in content.reversed() {
            switch block["type"] as? String {
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return AgentActivity(tool: name, detail: clip(toolDetail(name: name, input: block["input"] as? [String: Any] ?? [:])), at: at)
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return AgentActivity(tool: nil, detail: clip(firstLine(text)), at: at) }
            default: continue
            }
        }
        return nil
    }

    static func toolDetail(name: String, input: [String: Any]) -> String {
        func text(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let description = text("description") { return firstLine(description) }
        if let path = text("file_path") ?? text("notebook_path") ?? text("path") { return (path as NSString).lastPathComponent }
        if let command = text("command") { return firstLine(command) }
        if let pattern = text("pattern") ?? text("query") ?? text("url") ?? text("prompt") ?? text("skill") { return firstLine(pattern) }
        return ""
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).first ?? "")
    }

    static func clip(_ text: String, to limit: Int = 110) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
