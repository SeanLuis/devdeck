import Foundation

/// One minute of the machine: the totals and who was using the memory. Small enough to keep a week on disk.
public struct TimelinePoint: Codable, Hashable, Sendable, Identifiable {
    public struct Source: Codable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let kind: String
        public let memMB: Int
        public let cpu: Int

        public init(id: String, name: String, kind: String, memMB: Int, cpu: Int) {
            self.id = id; self.name = name; self.kind = kind; self.memMB = memMB; self.cpu = cpu
        }
    }

    /// Minutes since 1970.
    public let minute: Int
    public let memPercent: Double
    public let memUsedMB: Int
    public let swapMB: Int
    public let cpu: Double
    public let pressure: Int
    public let sources: [Source]

    public var id: Int { minute }
    public var date: Date { Date(timeIntervalSince1970: Double(minute) * 60) }

    public init(minute: Int, memPercent: Double, memUsedMB: Int, swapMB: Int, cpu: Double, pressure: Int, sources: [Source]) {
        self.minute = minute; self.memPercent = memPercent; self.memUsedMB = memUsedMB; self.swapMB = swapMB
        self.cpu = cpu; self.pressure = pressure; self.sources = sources
    }

    public static func make(snapshot: Snapshot, system: SystemSample, top: Int = 14) -> TimelinePoint {
        let sources = snapshot.groups.filter { $0.kind != .system }.prefix(top).map {
            Source(id: $0.id, name: $0.name, kind: $0.kind.rawValue, memMB: Int(Fmt.mb($0.memoryBytes)), cpu: Int($0.cpuPercent))
        }
        return TimelinePoint(minute: Int(system.time.timeIntervalSince1970 / 60), memPercent: (system.memPercent * 10).rounded() / 10,
                             memUsedMB: Int(Fmt.mb(system.memUsed)), swapMB: Int(Fmt.mb(system.swapUsed)), cpu: system.cpuPercent.rounded(),
                             pressure: system.pressure, sources: Array(sources))
    }
}

/// The timeline on disk: one JSON line per minute, one file per day, a week kept.
public final class TimelineStore: @unchecked Sendable {
    public let directory: URL
    public var keepDays = 7
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ day: String) -> URL { directory.appendingPathComponent(day + ".jsonl") }

    public func append(_ point: TimelinePoint) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? JSONEncoder().encode(point) else { return }
        data.append(0x0A)
        let url = file(AgentUsageReport.dayString(point.date))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            prune(now: point.date)
        }
    }

    /// Points between two dates, oldest first.
    public func load(from start: Date, to end: Date = Date()) -> [TimelinePoint] {
        lock.lock(); defer { lock.unlock() }
        var out: [TimelinePoint] = []
        let first = Int(start.timeIntervalSince1970 / 60), last = Int(end.timeIntervalSince1970 / 60)
        var day = start
        let decoder = JSONDecoder()
        while AgentUsageReport.dayString(day) <= AgentUsageReport.dayString(end) {
            if let data = try? Data(contentsOf: file(AgentUsageReport.dayString(day))) {
                for line in data.split(separator: 0x0A) {
                    guard let point = try? decoder.decode(TimelinePoint.self, from: Data(line)), point.minute >= first, point.minute <= last else { continue }
                    out.append(point)
                }
            }
            day = day.addingTimeInterval(86_400)
        }
        return out.sorted { $0.minute < $1.minute }
    }

    private func prune(now: Date) {
        let oldest = AgentUsageReport.dayString(now.addingTimeInterval(-Double(keepDays) * 86_400))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".jsonl") {
            if String(name.dropLast(6)) < oldest { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }
}

/// Memory that only goes up: the mark of a leak.
public struct MemoryLeak: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let fromMB: Int
    public let toMB: Int
    public let hours: Double

    public var growthMB: Int { toMB - fromMB }
    public var perHourMB: Int { hours > 0 ? Int(Double(growthMB) / hours) : 0 }
}

/// A moment worth looking at: memory at the limit or swap jumping, and who grew right before.
public struct TimelineMoment: Hashable, Sendable, Identifiable {
    public enum Reason: String, Sendable { case pressure, memory, swap }

    public let minute: Int
    public let reason: Reason
    public let memPercent: Double
    public let swapMB: Int
    /// Who grew the most in the ten minutes before, and by how much.
    public let culprit: String?
    public let culpritGrowthMB: Int

    public var id: Int { minute }
    public var date: Date { Date(timeIntervalSince1970: Double(minute) * 60) }
}

public enum TimelineAnalysis {
    /// Sources whose memory rose steadily over the window (at least `minHours`), by at least `minGrowthMB`.
    public static func leaks(_ points: [TimelinePoint], minHours: Double = 1, minGrowthMB: Int = 400) -> [MemoryLeak] {
        var series: [String: [(minute: Int, mb: Int, name: String, kind: String)]] = [:]
        for point in points { for source in point.sources { series[source.id, default: []].append((point.minute, source.memMB, source.name, source.kind)) } }
        var found: [MemoryLeak] = []
        for (id, values) in series {
            guard let first = values.first, let last = values.last, values.count >= 30 else { continue }
            let hours = Double(last.minute - first.minute) / 60
            guard hours >= minHours, first.kind != GroupKind.browser.rawValue || hours >= 3 else { continue }
            // Compare thirds, not single points: one spike is not a leak.
            let third = values.count / 3
            func median(_ slice: ArraySlice<(minute: Int, mb: Int, name: String, kind: String)>) -> Int {
                let sorted = slice.map(\.mb).sorted()
                return sorted[sorted.count / 2]
            }
            let start = median(values[..<third]), middle = median(values[third..<(2 * third)]), end = median(values[(2 * third)...])
            guard end - start >= minGrowthMB, middle >= start, end >= middle, Double(end) >= Double(start) * 1.25 else { continue }
            // It must rarely go down: a process that grows and shrinks is just busy.
            var drops = 0
            for index in 1..<values.count where values[index].mb < values[index - 1].mb - max(40, values[index - 1].mb / 20) { drops += 1 }
            guard Double(drops) / Double(values.count) < 0.04 else { continue }
            found.append(MemoryLeak(id: id, name: last.name, kind: last.kind, fromMB: start, toMB: end, hours: hours))
        }
        return found.sorted { $0.growthMB > $1.growthMB }
    }

    /// Minutes where memory hit the limit or swap jumped, merged when they are close, newest first.
    public static func moments(_ points: [TimelinePoint], limit: Int = 12) -> [TimelineMoment] {
        var out: [TimelineMoment] = []
        var lastMinute = -1_000_000
        for (index, point) in points.enumerated() {
            let before = index >= 10 ? points[index - 10] : points.first
            let swapJump = before.map { point.swapMB - $0.swapMB } ?? 0
            let reason: TimelineMoment.Reason?
            if point.pressure >= 4 { reason = .pressure } else if point.memPercent >= 90 { reason = .memory } else if swapJump >= 700 { reason = .swap } else { reason = nil }
            guard let reason, point.minute - lastMinute > 20 else { if reason != nil { lastMinute = point.minute }; continue }
            lastMinute = point.minute
            var culprit: String?
            var growth = 0
            if let before {
                let earlier = Dictionary(before.sources.map { ($0.id, $0.memMB) }, uniquingKeysWith: { a, _ in a })
                for source in point.sources {
                    let delta = source.memMB - (earlier[source.id] ?? 0)
                    if delta > growth { growth = delta; culprit = source.name }
                }
            }
            out.append(TimelineMoment(minute: point.minute, reason: reason, memPercent: point.memPercent, swapMB: point.swapMB,
                                      culprit: growth >= 200 ? culprit : nil, culpritGrowthMB: growth))
        }
        return Array(out.reversed().prefix(limit))
    }

    /// At most `count` points, evenly spaced, so a week draws as fast as an hour.
    public static func thin(_ points: [TimelinePoint], to count: Int = 360) -> [TimelinePoint] {
        guard points.count > count else { return points }
        let step = Double(points.count) / Double(count)
        return (0..<count).map { points[min(points.count - 1, Int(Double($0) * step))] }
    }
}
