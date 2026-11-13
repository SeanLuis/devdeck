import Foundation

public struct ContainerPort: Sendable, Hashable, Codable {
    public let hostPort: UInt16
    public let containerPort: UInt16
    public let proto: String
}

public struct ContainerInfo: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let ports: [ContainerPort]
    public let composeProject: String?
    public let workingDir: String?
    public var memoryBytes: UInt64?
    public var cpuPercent: Double?

    public var isRunning: Bool { state == "running" }
}

public enum DockerProbe {
    public static func dockerBinary(env: [String: String]) -> String? {
        LoginEnvironment.which("docker", env: env)
    }

    public static func containers(docker: String, env: [String: String]) async -> [ContainerInfo]? {
        let ps = await Shell.run(docker, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"], env: env, timeout: 6)
        guard ps.ok else { return nil }
        var containers = ps.stdout.split(separator: "\n").compactMap { parse(line: String($0)) }
        guard containers.contains(where: \.isRunning) else { return containers }

        let stats = await Shell.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"], env: env, timeout: 12)
        if stats.ok {
            var byName: [String: (UInt64, Double)] = [:]
            for line in stats.stdout.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let name = obj["Name"] as? String else { continue }
                let mem = parseSize((obj["MemUsage"] as? String)?.components(separatedBy: "/").first ?? "")
                let cpu = Double((obj["CPUPerc"] as? String ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
                byName[name] = (mem, cpu)
            }
            for i in containers.indices {
                if let s = byName[containers[i].name] {
                    containers[i].memoryBytes = s.0
                    containers[i].cpuPercent = s.1
                }
            }
        }
        return containers
    }

    static func parse(line: String) -> ContainerInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let labels = parseLabels(obj["Labels"] as? String ?? "")
        return ContainerInfo(
            id: obj["ID"] as? String ?? UUID().uuidString,
            name: obj["Names"] as? String ?? "?",
            image: obj["Image"] as? String ?? "",
            state: obj["State"] as? String ?? "",
            status: obj["Status"] as? String ?? "",
            ports: parsePorts(obj["Ports"] as? String ?? ""),
            composeProject: labels["com.docker.compose.project"],
            workingDir: labels["com.docker.compose.project.working_dir"],
            memoryBytes: nil,
            cpuPercent: nil
        )
    }

    static func parseLabels(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in raw.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    /// "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp"
    static func parsePorts(_ raw: String) -> [ContainerPort] {
        var seen = Set<ContainerPort>()
        let regex = try? NSRegularExpression(pattern: #":(\d+)->(\d+)/(tcp|udp)"#)
        let ns = raw as NSString
        regex?.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match,
                  let host = UInt16(ns.substring(with: m.range(at: 1))),
                  let container = UInt16(ns.substring(with: m.range(at: 2))) else { return }
            seen.insert(ContainerPort(hostPort: host, containerPort: container, proto: ns.substring(with: m.range(at: 3))))
        }
        return seen.sorted { $0.hostPort < $1.hostPort }
    }

    /// "1.56GiB", "512MiB", "12.3kB"
    static func parseSize(_ raw: String) -> UInt64 {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TiB", 1_099_511_627_776), ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1024),
                                         ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            return UInt64((Double(s.dropLast(suffix.count)) ?? 0) * factor)
        }
        return 0
    }
}
