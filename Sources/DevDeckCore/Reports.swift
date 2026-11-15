import Foundation

/// What the Mac is doing, as plain data: the same reading the app shows, for the command line and for agents.
/// Everything here only reads.
public enum Reports {
    public static let topics = ["status", "top", "ports", "agents", "sessions", "branches", "today"]

    /// Two samples a moment apart, so CPU figures mean something.
    public static func sample() async -> (Snapshot, SystemSample) {
        let sampler = Sampler()
        _ = await sampler.sample()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return await sampler.sample()
    }

    /// Two decimals, as a number that prints as written (a Double would print 283.75999999999999).
    static func gb(_ bytes: UInt64) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", Double(bytes) / 1_073_741_824)) }

    public static func status(_ snapshot: Snapshot, _ system: SystemSample) -> [String: Any] {
        ["memory_used_gb": gb(system.memUsed), "memory_total_gb": gb(system.memTotal), "memory_percent": system.memPercent.rounded(),
         "pressure": system.pressureLabel, "swap_used_gb": gb(system.swapUsed), "cpu_percent": system.cpuPercent.rounded(),
         "disk_free_gb": gb(system.diskFree), "listening_ports": snapshot.ports.count, "headless_browsers": snapshot.headlessBrowserCount,
         "heaviest": snapshot.groups.first { $0.kind != .system }.map { ["name": $0.name, "memory_gb": gb($0.memoryBytes)] as [String: Any] } ?? [:]]
    }

    public static func top(_ snapshot: Snapshot, limit: Int = 12) -> [[String: Any]] {
        snapshot.groups.prefix(limit).map { group in
            var row: [String: Any] = ["name": group.name, "kind": group.kind.rawValue, "memory_gb": gb(group.memoryBytes),
                                      "cpu_percent": NSDecimalNumber(string: String(format: "%.1f", group.cpuPercent)), "processes": group.processCount]
            if let root = group.projectRoot { row["folder"] = root }
            let ports = Set(group.ports.map(\.port)).sorted()
            if !ports.isEmpty { row["ports"] = ports.map(Int.init) }
            return row
        }
    }

    public static func ports(_ snapshot: Snapshot) -> [[String: Any]] {
        snapshot.ports.sorted { $0.port < $1.port }.map {
            ["port": Int($0.port), "address": $0.address, "pid": Int($0.pid), "process": $0.processName, "owner": $0.groupName]
        }
    }

    public static func agents(_ usage: AgentUsageReport, prices: PriceTable = PriceTable()) -> [[String: Any]] {
        let today = AgentUsageReport.dayString(Date())
        return usage.agents.map { agent in
            let week = usage.total(agent: agent)
            var row: [String: Any] = ["agent": agent, "tokens_today": Int(usage.total(agent: agent, day: today).billable), "tokens_7_days": Int(week.billable),
                                      "cache_read_7_days": Int(week.cacheRead), "responses_7_days": week.messages]
            let cost = usage.cost(prices) { $0.agent == agent }
            if cost.hasPrice { row["list_price_usd_7_days"] = (cost.dollars * 100).rounded() / 100 }
            return row
        }
    }

    public static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func branches(_ repos: [GitRepo]) -> [[String: Any]] {
        repos.flatMap { repo in
            repo.worktrees.map { tree -> [String: Any] in
                var row: [String: Any] = ["repository": repo.name, "folder": tree.path, "branch": tree.branch ?? "(detached \(tree.head))",
                                          "worktree": !tree.isMain, "uncommitted": tree.changes, "ahead": tree.ahead, "behind": tree.behind]
                if let size = tree.sizeBytes { row["size_gb"] = gb(size) }
                if let commit = tree.lastCommit { row["last_commit"] = ISO8601DateFormatter().string(from: commit) }
                return row
            }
        }
    }

    /// Aligned columns for a terminal.
    public static func table(_ rows: [[String: Any]], columns: [String]) -> String {
        func text(_ value: Any?) -> String {
            switch value {
            case let list as [Any]: return list.map { "\($0)" }.joined(separator: ",")
            case let number as Double: return number == number.rounded() ? String(Int(number)) : String(number)
            case .some(let other): return "\(other)"
            case .none: return ""
            }
        }
        let cells = [columns] + rows.map { row in columns.map { text(row[$0]) } }
        let widths = columns.indices.map { index in cells.map { $0[index].count }.max() ?? 0 }
        return cells.map { line in
            line.enumerated().map { $0.element.padding(toLength: widths[$0.offset], withPad: " ", startingAt: 0) }.joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

/// A Model Context Protocol server over stdio: lets a coding agent ask what the Mac is doing before it starts
/// another dev server or wonders why the machine is slow. Most tools only read. The two that ask for something to be
/// done only pass the request on: the person approves or refuses it in DevDeck, and nothing runs from here.
public struct MCPServer: Sendable {
    public struct Tool: @unchecked Sendable {
        public let name: String
        public let description: String
        /// JSON Schema of each argument, by name.
        public let properties: [String: Any]
        public let required: [String]
        public let readOnly: Bool
        public let run: @Sendable ([String: Any]) async -> Any

        public init(name: String, description: String, run: @escaping @Sendable () async -> Any) {
            self.name = name; self.description = description; properties = [:]; required = []; readOnly = true
            self.run = { _ in await run() }
        }

        public init(name: String, description: String, properties: [String: Any], required: [String], readOnly: Bool,
                    call: @escaping @Sendable ([String: Any]) async -> Any) {
            self.name = name; self.description = description; self.properties = properties; self.required = required
            self.readOnly = readOnly; run = call
        }
    }

    public let tools: [Tool]
    public let version: String

    public init(version: String, tools: [Tool]) { self.version = version; self.tools = tools }

    /// One request → its response; nil for notifications.
    public func handle(_ request: [String: Any]) async -> [String: Any]? {
        guard let id = request["id"] else { return nil }
        func reply(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch request["method"] as? String {
        case "initialize":
            let asked = (request["params"] as? [String: Any])?["protocolVersion"] as? String
            return reply(["protocolVersion": asked ?? "2025-06-18", "capabilities": ["tools": [String: Any]()],
                          "serverInfo": ["name": "devdeck", "version": version]] as [String: Any])
        case "ping": return reply([String: Any]())
        case "tools/list":
            return reply(["tools": tools.map { ["name": $0.name, "description": $0.description,
                                                "inputSchema": ["type": "object", "properties": $0.properties, "required": $0.required,
                                                                "additionalProperties": false] as [String: Any],
                                                "annotations": ["readOnlyHint": $0.readOnly]] as [String: Any] }])
        case "tools/call":
            let params = request["params"] as? [String: Any]
            let name = params?["name"] as? String
            let arguments = (params?["arguments"] as? [String: Any]) ?? [:]
            guard let tool = tools.first(where: { $0.name == name }) else {
                return reply(["content": [["type": "text", "text": "Unknown tool: \(name ?? "")"]], "isError": true] as [String: Any])
            }
            if let missing = tool.required.first(where: { arguments[$0] == nil }) {
                return reply(["content": [["type": "text", "text": "Missing argument: \(missing)"]], "isError": true] as [String: Any])
            }
            return reply(["content": [["type": "text", "text": Reports.json(await tool.run(arguments))]]])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"] as [String: Any]]
        }
    }

    /// Serves until stdin closes. One JSON object per line, as the stdio transport requires.
    public func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = await handle(request),
                  let out = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
            FileHandle.standardOutput.write(out + Data([0x0A]))
        }
    }

    /// A tool that asks the person, through DevDeck, to allow one action on a port.
    static func requestTool(name: String, action: String, description: String, base: URL) -> Tool {
        Tool(name: name, description: description,
             properties: ["port": ["type": "integer", "minimum": 1, "maximum": 65_535, "description": "TCP port on this Mac."] as [String: Any],
                          "reason": ["type": "string", "description": "One sentence the person will read: why you need this."] as [String: Any]],
             required: ["port"], readOnly: false) { arguments in
            guard let port = (arguments["port"] as? NSNumber)?.intValue else { return ["approved": false, "done": false, "detail": "port must be a number."] as [String: Any] }
            return await AgentRequests.ask(AgentRequest(action: action, port: port, reason: arguments["reason"] as? String), base: base)
        }
    }

    public static func standard(version: String, base: URL = JSONStore().directory) -> MCPServer {
        MCPServer(version: version, tools: [
            requestTool(name: "request_free_port", action: "free_port", description: "Ask the person at this Mac to stop whatever is listening on a TCP port, so you can use it. DevDeck shows them the request and nothing is stopped unless they approve; they have about 90 seconds. Returns whether it was approved and done. Check listening_ports first.", base: base),
            requestTool(name: "request_restart_server", action: "restart_server", description: "Ask the person at this Mac to restart the dev server listening on a TCP port, with the same command and environment. DevDeck shows them the request and nothing is restarted unless they approve; they have about 90 seconds. Returns whether it was approved and done.", base: base),
            Tool(name: "system_status", description: "Memory, swap, CPU, disk and memory pressure of this Mac right now, and what uses the most memory.") {
                let (snapshot, system) = await Reports.sample()
                return Reports.status(snapshot, system)
            },
            Tool(name: "top_consumers", description: "What is using memory and CPU on this Mac, grouped by origin: each project (with its folder and ports), coding agent, browser, Docker and app.") {
                Reports.top(await Reports.sample().0)
            },
            Tool(name: "listening_ports", description: "Every TCP port being listened on, with the process and the project or app that owns it. Check this before starting a server on a port.") {
                Reports.ports(await Reports.sample().0)
            },
            Tool(name: "branches", description: "Branches and git worktrees of the repositories coding agents worked in during the last two weeks: uncommitted files, commits ahead and behind, and disk size of each extra worktree.") {
                let recent = Date().addingTimeInterval(-14 * 86_400)
                return Reports.branches(await GitWork.scan(folders: SessionLibrary.list().filter { $0.modified >= recent }.map(\.folder)))
            },
            Tool(name: "today", description: "What coding agents did today on this Mac, per project: tokens, cost at API list prices, session titles and commits.") {
                DailyDigests.report(await DailyDigests.load(day: AgentUsageReport.dayString(Date()), env: ProcessInfo.processInfo.environment, prices: PriceTable()))
            },
            Tool(name: "agent_usage", description: "Tokens each coding agent (Claude Code, Codex and others) spent today and in the last 7 days on this Mac, read from their local logs.") {
                Reports.agents(await AgentUsageScanner().scan(days: 7, env: ProcessInfo.processInfo.environment))
            },
        ])
    }
}
