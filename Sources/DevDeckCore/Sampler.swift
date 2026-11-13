import Darwin
import Foundation

/// Owns the low-level scanners; every sample happens off the main thread.
public actor Sampler {
    private let scanner = ProcessScanner()
    private let stats = SystemStatsReader()
    public nonisolated let resolver = ProjectResolver()
    private var containers: [ContainerInfo] = []
    private var cachedPorts: [Int32: [RawListeningPort]] = [:]
    private var tick = 0

    public init() {}

    public func sample() -> (Snapshot, SystemSample) {
        let processes = scanner.scan()
        if tick % 2 == 0 {
            var ports: [Int32: [RawListeningPort]] = [:]
            for p in processes where p.isMine {
                let list = scanner.listeningPorts(pid: p.pid)
                if !list.isEmpty { ports[p.pid] = list }
            }
            cachedPorts = ports
        }
        tick += 1
        let classifier = Classifier(resolver: resolver, myUID: getuid(), selfPid: getpid())
        let snapshot = classifier.build(processes: processes, ports: cachedPorts, containers: containers, now: Date())
        return (snapshot, stats.read())
    }

    public func setContainers(_ list: [ContainerInfo]) { containers = list }

    /// argv + environment of a running process (only works for the user's own processes).
    public func launchContext(of pid: Int32) -> (args: [String], env: [String: String])? {
        guard let raw = scanner.readArgs(pid, includeEnv: true) else { return nil }
        var env: [String: String] = [:]
        for entry in raw.env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (raw.args, env)
    }
}
