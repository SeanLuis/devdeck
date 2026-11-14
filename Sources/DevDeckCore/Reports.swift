import Foundation

/// What the Mac is doing, as plain data: the same reading the app shows, for the command line and for agents.
/// Everything here only reads.
public enum Reports {
    public static let topics = ["status", "top", "ports", "agents"]

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
/// another dev server or wonders why the machine is slow. Read-only tools; nothing is closed or changed from here.
public struct MCPServer: Sendable {
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let run: @Sendable () async -> Any
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
                                                "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false] as [String: Any],
                                                "annotations": ["readOnlyHint": true]] as [String: Any] }])
        case "tools/call":
            let name = (request["params"] as? [String: Any])?["name"] as? String
            guard let tool = tools.first(where: { $0.name == name }) else {
                return reply(["content": [["type": "text", "text": "Unknown tool: \(name ?? "")"]], "isError": true] as [String: Any])
            }
            return reply(["content": [["type": "text", "text": Reports.json(await tool.run())]]])
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

    public static func standard(version: String) -> MCPServer {
        MCPServer(version: version, tools: [
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
            Tool(name: "agent_usage", description: "Tokens each coding agent (Claude Code, Codex and others) spent today and in the last 7 days on this Mac, read from their local logs.") {
                Reports.agents(await AgentUsageScanner().scan(days: 7, env: ProcessInfo.processInfo.environment))
            },
        ])
    }
}
