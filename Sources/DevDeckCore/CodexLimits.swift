import Foundation

/// Codex's limits, asked to Codex itself: `codex app-server` answers one `account/rateLimits/read` over stdio
/// and is closed. The CLI uses its own login; DevDeck never reads or sends Codex's token for this.
/// The session logs only move while Codex runs here; this reading follows the whole plan.
public enum CodexLimits {
    /// The `result` of `account/rateLimits/read` → plan.
    public static func parse(_ result: [String: Any], now: Date = Date()) -> CodexPlan? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        var plan = CodexPlan()
        plan.planType = limits["planType"] as? String
        func window(_ key: String) -> (Double, Date?)? {
            guard let window = limits[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            return (used, (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        if let primary = window("primary") { plan.primaryUsedPercent = primary.0; plan.primaryResets = primary.1 }
        if let secondary = window("secondary") { plan.secondaryUsedPercent = secondary.0; plan.secondaryResets = secondary.1 }
        if let credits = limits["credits"] as? [String: Any] {
            if (credits["unlimited"] as? Bool) == true { plan.credits = "créditos ilimitados" }
            else if (credits["hasCredits"] as? Bool) == true, let balance = credits["balance"] as? String { plan.credits = L("créditos: %@", balance) }
        }
        plan.readAt = now
        return plan.primaryUsedPercent == nil && plan.secondaryUsedPercent == nil ? nil : plan
    }

    /// Runs the CLI, asks once and stops it. nil when there is no answer in `timeout` seconds.
    public static func read(binary: String, env: [String: String], timeout: TimeInterval = 12) -> CodexPlan? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer { if process.isRunning { process.terminate() } }
        signal(SIGPIPE, SIG_IGN)
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "devdeck", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
        ]
        for request in requests {
            guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }
        let found = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var plan: CodexPlan? }
        let box = Box()
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                    box.plan = (object["result"] as? [String: Any]).flatMap { parse($0) }
                    found.signal()
                    return
                }
            }
            found.signal()
        }
        _ = found.wait(timeout: .now() + timeout)
        return box.plan
    }
}

/// When the short window runs out at the pace of the last hour.
public enum SessionPace {
    /// - Parameters:
    ///   - percent: the window's reading from the account.
    ///   - windowTokens: tokens spent since the window started.
    ///   - lastHourTokens: tokens spent in the last 60 minutes.
    /// The account's % moves in whole steps every few minutes; tokens move with every answer, so the pace is taken
    /// from tokens and converted to % with the reading. nil when it lasts until the reset, or there is too little to say.
    public static func runsOut(percent: Double, resetsAt: Date?, windowTokens: Double, lastHourTokens: Double, now: Date = Date(),
                               windowLength: TimeInterval = 5 * 3600) -> Date? {
        guard let resetsAt, resetsAt > now, percent >= 5, percent < 100, windowTokens > 0, lastHourTokens > 0 else { return nil }
        let elapsed = windowLength - resetsAt.timeIntervalSince(now)
        guard elapsed >= 600 else { return nil }   // right after a reset nothing can be said
        let percentPerHour = percent * lastHourTokens / windowTokens
        guard percentPerHour > 0.5 else { return nil }
        let date = now.addingTimeInterval((100 - percent) / percentPerHour * 3600)
        return date < resetsAt ? date : nil
    }
}

extension AgentUsageReport {
    /// Tokens an agent spent since `start`, by clock hour, with the first and the current hour counted in proportion.
    public func tokens(agent: String, since start: Date, now: Date = Date()) -> Double {
        let first = Int(start.timeIntervalSince1970 / 3600), last = Int(now.timeIntervalSince1970 / 3600)
        var total = 0.0
        for (hour, value) in hourly[agent] ?? [:] where hour >= first && hour <= last {
            var share = 1.0
            if hour == first, first != last { share = 1 - (start.timeIntervalSince1970 / 3600 - Double(first)) }
            total += Double(value.billable) * share
        }
        return total
    }
}
