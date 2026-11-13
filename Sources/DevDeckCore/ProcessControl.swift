import Darwin
import Foundation

/// Everything needed to start a dev server again exactly as it was: command, folder and environment.
public struct LaunchRecipe: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(cwd)|\(argv.joined(separator: " "))" }
    public var projectRoot: String
    public var cwd: String
    public var argv: [String]
    public var env: [String: String]
    public var label: String
    public var capturedAt: Date
    public var ports: [UInt16]

    public init(projectRoot: String, cwd: String, argv: [String], env: [String: String], label: String, capturedAt: Date = Date(), ports: [UInt16] = []) {
        self.projectRoot = projectRoot; self.cwd = cwd; self.argv = argv; self.env = env
        self.label = label; self.capturedAt = capturedAt; self.ports = ports
    }

    public var commandLine: String { argv.joined(separator: " ") }
}

public enum ProcessControlError: LocalizedError {
    case emptyCommand
    case executableNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .emptyCommand: return L("Comando vacío")
        case .executableNotFound(let name): return L("No encuentro el ejecutable '%@' en el PATH", name)
        }
    }
}

public enum ProcessControl {
    /// Start time of a live process, used to make sure a PID was not reused since the snapshot.
    public static func startTime(of pid: Int32) -> Date? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
    }

    /// Like `terminate`, but skips any PID whose start time no longer matches (it died and was reused).
    @discardableResult
    public static func terminate(_ pids: [Int32], expectedStarts: [Int32: Date], grace: TimeInterval = 4) async -> (graceful: Int, forced: Int) {
        let verified = pids.filter { pid in
            guard let expected = expectedStarts[pid], let actual = startTime(of: pid) else { return false }
            return abs(actual.timeIntervalSince(expected)) < 1
        }
        return await terminate(verified, grace: grace)
    }

    /// SIGTERM the given processes (children first), wait, then SIGKILL survivors.
    @discardableResult
    public static func terminate(_ pids: [Int32], grace: TimeInterval = 4) async -> (graceful: Int, forced: Int) {
        let me = getpid()
        let targets = pids.filter { $0 > 1 && $0 != me }
        guard !targets.isEmpty else { return (0, 0) }
        for pid in targets.reversed() { kill(pid, SIGTERM) }
        var alive = targets
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            alive = alive.filter { kill($0, 0) == 0 }
            if alive.isEmpty { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        for pid in alive { kill(pid, SIGKILL) }
        return (targets.count - alive.count, alive.count)
    }

    /// True when something accepts TCP connections on localhost:`port`.
    public static func isListening(port: UInt16) -> Bool {
        for family in [AF_INET, AF_INET6] {
            let fd = socket(family, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var result: Int32
            if family == AF_INET {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            } else {
                var addr = sockaddr_in6()
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_addr = in6addr_loopback
                result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            }
            if result == 0 { return true }
        }
        return false
    }

    /// Returns false if some port is still taken after the timeout.
    @discardableResult
    public static func waitUntilFree(ports: [UInt16], timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, ports.contains(where: isListening) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !ports.contains(where: isListening)
    }

    /// Node and friends rewrite their process title ("npm run dev"), which collapses argv into one string.
    public static func normalizedArgv(_ argv: [String]) -> [String] {
        guard argv.count == 1, let only = argv.first, only.contains(" "), !FileManager.default.fileExists(atPath: only) else { return argv }
        return only.split(separator: " ").map(String.init)
    }

    /// Starts a recipe detached from DevDeck's lifetime; stdout/stderr go to a log file.
    public static func launch(_ recipe: LaunchRecipe, logDirectory: URL, fallbackEnv: [String: String]) throws -> (Process, URL) {
        let argv = normalizedArgv(recipe.argv)
        guard let first = argv.first else { throw ProcessControlError.emptyCommand }
        var env = recipe.env.isEmpty ? fallbackEnv : recipe.env
        if env["PATH"] == nil { env["PATH"] = fallbackEnv["PATH"] }
        env["DEVDECK_MANAGED"] = "1"

        let process = Process()
        if let exe = LoginEnvironment.which(first, env: env) ?? LoginEnvironment.which(first, env: fallbackEnv) {
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = Array(argv.dropFirst())
        } else {
            // Last resort: let the login shell resolve aliases/functions.
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", argv.map(shellQuote).joined(separator: " ")]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: recipe.cwd)
        process.environment = env

        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let slug = (recipe.projectRoot as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let log = logDirectory.appendingPathComponent("\(slug)-\(stamp).log")
        let header = "$ cd \(recipe.cwd)\n$ \(argv.joined(separator: " "))\n\n"
        FileManager.default.createFile(atPath: log.path, contents: Data(header.utf8))
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return (process, log)
    }

    static func shellQuote(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Package scripts (`dev`, `start`…) for projects that are not running.
public struct PackageScripts: Sendable {
    public let dir: String
    public let manager: String
    public let scripts: [String: String]

    public static func read(dir: String, projectRoot: String) -> PackageScripts? {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: String], !scripts.isEmpty else { return nil }
        return PackageScripts(dir: dir, manager: packageManager(dir: dir, projectRoot: projectRoot), scripts: scripts)
    }

    public static func packageManager(dir: String, projectRoot: String) -> String {
        let fm = FileManager.default
        for d in [dir, projectRoot] {
            if fm.fileExists(atPath: d + "/pnpm-lock.yaml") { return "pnpm" }
            if fm.fileExists(atPath: d + "/bun.lock") || fm.fileExists(atPath: d + "/bun.lockb") { return "bun" }
            if fm.fileExists(atPath: d + "/yarn.lock") { return "yarn" }
            if fm.fileExists(atPath: d + "/package-lock.json") { return "npm" }
        }
        return "npm"
    }

    public func recipe(script: String, projectRoot: String, env: [String: String]) -> LaunchRecipe {
        LaunchRecipe(projectRoot: projectRoot, cwd: dir, argv: [manager, "run", script], env: env,
                     label: "\(manager) run \(script)")
    }

    /// Most likely "start the dev server" scripts first.
    public var preferredOrder: [String] {
        let priority = ["dev", "start", "serve", "develop", "preview", "watch"]
        return scripts.keys.sorted { a, b in
            let ia = priority.firstIndex(of: a) ?? Int.max, ib = priority.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
    }
}
