import Foundation

/// Something a coding agent asks the person to let DevDeck do. Nothing runs until they approve it in the app.
public struct AgentRequest: Codable, Identifiable, Hashable, Sendable {
    public static let actions = ["free_port", "restart_server"]

    public let id: String
    /// "free_port" (stop whatever listens on it) | "restart_server" (same command, same environment).
    public let action: String
    public let port: Int
    /// Why the agent wants it, in its own words; shown to the person as is.
    public let reason: String?
    public let at: Date

    public init(id: String = UUID().uuidString, action: String, port: Int, reason: String?, at: Date = Date()) {
        self.id = id; self.action = action; self.port = port; self.reason = reason.map { String($0.prefix(240)) }; self.at = at
    }
}

public struct AgentRequestResult: Codable, Hashable, Sendable {
    public let id: String
    public let approved: Bool
    public let done: Bool
    public let detail: String

    public init(id: String, approved: Bool, done: Bool, detail: String) {
        self.id = id; self.approved = approved; self.done = done; self.detail = detail
    }
}

/// The mailbox between `devdeck mcp` (which an agent talks to) and the running app (where the person approves):
/// one small file per request and one per answer, in DevDeck's own folder.
public enum AgentRequests {
    /// How long a request waits for the person before it is given up.
    public static let patience: TimeInterval = 90

    public static func directory(_ base: URL) -> URL { base.appendingPathComponent("requests", isDirectory: true) }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    public static func submit(_ request: AgentRequest, base: URL) throws {
        let folder = directory(base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try coder().0.encode(request).write(to: folder.appendingPathComponent(request.id + ".json"), options: .atomic)
    }

    /// Requests nobody answered yet, oldest first. Old ones are thrown away: the agent stopped waiting.
    public static func pending(base: URL, now: Date = Date()) -> [AgentRequest] {
        let folder = directory(base)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [AgentRequest] = []
        for name in names where name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            let answer = name.hasSuffix(".result.json")
            guard let data = try? Data(contentsOf: url) else { continue }
            if answer {
                let age = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date).map { now.timeIntervalSince($0) } ?? 0
                if age > 600 { try? FileManager.default.removeItem(at: url) }
                continue
            }
            guard let request = try? coder().1.decode(AgentRequest.self, from: data), now.timeIntervalSince(request.at) <= patience,
                  AgentRequest.actions.contains(request.action) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            out.append(request)
        }
        return out.sorted { $0.at < $1.at }
    }

    public static func answer(_ result: AgentRequestResult, base: URL) {
        let folder = directory(base)
        try? coder().0.encode(result).write(to: folder.appendingPathComponent(result.id + ".result.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(result.id + ".json"))
    }

    public static func result(of id: String, base: URL) -> AgentRequestResult? {
        let url = directory(base).appendingPathComponent(id + ".result.json")
        guard let data = try? Data(contentsOf: url), let result = try? coder().1.decode(AgentRequestResult.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return result
    }

    /// The app says "I am here" by touching a file; without it nobody can approve anything.
    public static func heartbeat(base: URL, now: Date = Date()) {
        let folder = directory(base)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("\(now.timeIntervalSince1970)".utf8).write(to: folder.appendingPathComponent("listening"))
    }

    public static func appListening(base: URL, now: Date = Date()) -> Bool {
        guard let text = try? String(contentsOf: directory(base).appendingPathComponent("listening"), encoding: .utf8), let at = Double(text) else { return false }
        return now.timeIntervalSince1970 - at < 6
    }

    /// Sends the request and waits for the person. Always comes back with something the agent can read.
    public static func ask(_ request: AgentRequest, base: URL, patience: TimeInterval = AgentRequests.patience) async -> [String: Any] {
        guard AgentRequest.actions.contains(request.action), (1...65_535).contains(request.port) else {
            return ["approved": false, "done": false, "detail": "Unknown action or port."]
        }
        guard appListening(base: base) else {
            return ["approved": false, "done": false, "detail": "DevDeck is not open on this Mac, so nobody can approve this. Ask the person to open DevDeck or to do it themselves."]
        }
        do { try submit(request, base: base) } catch {
            return ["approved": false, "done": false, "detail": "The request could not be written."]
        }
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            if let result = result(of: request.id, base: base) {
                return ["approved": result.approved, "done": result.done, "detail": result.detail]
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        try? FileManager.default.removeItem(at: directory(base).appendingPathComponent(request.id + ".json"))
        return ["approved": false, "done": false, "detail": "The person did not answer in DevDeck. Nothing was changed."]
    }
}
