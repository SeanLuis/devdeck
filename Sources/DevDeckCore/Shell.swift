import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public var ok: Bool { status == 0 && !timedOut }
}

/// Runs short-lived helper commands (du, docker, git…) off the main thread with a hard timeout.
public enum Shell {
    public static func run(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runSync(executable, args, cwd: cwd, env: env, timeout: timeout))
            }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    public static func runSync(
        _ executable: String,
        _ args: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "\(error.localizedDescription)", timedOut: false)
        }

        let out = Buffer(), err = Buffer()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            out.set(outPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            err.set(errPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Grandchildren may keep the pipes open; never block forever on them.
        _ = readers.wait(timeout: .now() + 3)
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: out.get(), as: UTF8.self),
            stderr: String(decoding: err.get(), as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// The user's login-shell environment (PATH with nvm, pnpm, bun, brew…), which GUI apps don't inherit.
public enum LoginEnvironment {
    public static func load() async -> [String: String] {
        let marker = "__DEVDECK_ENV__"
        let result = await Shell.run("/bin/zsh", ["-l", "-i", "-c", "printf '\(marker)'; env -0"], timeout: 15)
        var env = ProcessInfo.processInfo.environment
        guard let range = result.stdout.range(of: marker) else { return env }
        for entry in result.stdout[range.upperBound...].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    public static func which(_ name: String, env: [String: String]) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin"]
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + extra
        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
