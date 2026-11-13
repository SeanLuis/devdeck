import Foundation

public enum KeychainError: LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail): return L("El llavero rechazó la operación: %@", detail)
        }
    }
}

/// Generic-password items, read and written through `/usr/bin/security`.
///
/// Going through `security` instead of the Security framework is deliberate: Claude Code creates its own item
/// with that tool, so the tool is already trusted to read it and macOS asks nothing. Secrets travel on stdin
/// (`security -i`), never in the argument list, and are never logged.
public struct Keychain: Sendable {
    /// A specific keychain file; nil = the user's default keychains. Tests use a throwaway one.
    public var path: String?

    public init(path: String? = nil) { self.path = path }

    static let tool = "/usr/bin/security"
    static let notFound: Int32 = 44
    /// `security -i` reads each command into a 4096-byte buffer; longer lines are cut silently.
    static let stdinLineLimit = 4096 - 64

    struct Output { let status: Int32; let stdout: Data; let stderr: String }

    static func run(_ args: [String], input: String? = nil, timeout: TimeInterval = 15) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return Output(status: -1, stdout: Data(), stderr: error.localizedDescription) }
        if let input {
            // The tool dying before it reads must be an error here, not a signal that ends the app.
            signal(SIGPIPE, SIG_IGN)
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return Output(status: process.terminationStatus, stdout: data, stderr: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Double-quoted for a `security -i` line, which is parsed like a shell line.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The secret of an item, or nil when there is no such item.
    public func get(service: String, account: String) throws -> String? {
        var args = ["find-generic-password", "-a", account, "-s", service, "-w"]
        if let path { args.append(path) }
        let result = Self.run(args)
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw KeychainError.failed("find rc=\(result.status)") }
        var text = String(decoding: result.stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    public func exists(service: String, account: String) -> Bool {
        var args = ["find-generic-password", "-a", account, "-s", service]
        if let path { args.append(path) }
        return Self.run(args).status == 0
    }

    /// Creates or replaces an item.
    public func set(service: String, account: String, secret: String) throws {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        var line = "add-generic-password -U -a \(Self.quote(account)) -s \(Self.quote(service)) -X \(hex)"
        if let path { line += " " + Self.quote(path) }
        let result: Output
        if line.utf8.count + 1 <= Self.stdinLineLimit {
            result = Self.run(["-i"], input: line + "\n")
        } else {
            // Too long for the tool's line buffer. Hex in the argument list is visible to this user's processes for
            // an instant; the alternative is a write that silently truncates and loses the login.
            var args = ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]
            if let path { args.append(path) }
            result = Self.run(args)
        }
        guard result.status == 0 else { throw KeychainError.failed("add rc=\(result.status)") }
        // `security -i` reports success even when a line failed: confirm by reading back.
        guard try get(service: service, account: account) == secret else { throw KeychainError.failed("verify") }
    }

    public func delete(service: String, account: String) throws {
        var args = ["delete-generic-password", "-a", account, "-s", service]
        if let path { args.append(path) }
        let result = Self.run(args)
        guard result.status == 0 || result.status == Self.notFound else { throw KeychainError.failed("delete rc=\(result.status)") }
    }
}
