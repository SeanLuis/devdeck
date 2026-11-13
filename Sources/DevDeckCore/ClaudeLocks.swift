import Foundation

/// Cooperates with the advisory locks Claude Code takes around its own files, so a change made here never lands
/// in the middle of a token refresh or a config write of a running session.
///
/// Claude Code uses lock *directories* (`mkdir` is the mutex): `~/.claude/.oauth_refresh.lock` and `~/.claude.lock`
/// around a token refresh (stale after 60 s), and `~/.claude.json.lock` around config writes (stale after 10 s).
public enum ClaudeLocks {
    public struct Timeout: LocalizedError {
        public var errorDescription: String? { L("Claude Code está ocupado escribiendo sus archivos. Inténtalo de nuevo en unos segundos.") }
    }

    public static func credentialLocks(home: String) -> [(path: String, stale: TimeInterval)] {
        [(home + "/.claude/.oauth_refresh.lock", 60), (home + "/.claude.lock", 60)]
    }

    public static func configLock(configPath: String) -> (path: String, stale: TimeInterval) {
        (configPath + ".lock", 10)
    }

    static func acquire(_ path: String, stale: TimeInterval, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let manager = FileManager.default
        while true {
            if (try? manager.createDirectory(atPath: path, withIntermediateDirectories: false)) != nil { return true }
            // Held. A holder that died leaves the directory behind: it is ours once it is older than the staleness window.
            if let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > stale {
                rmdir(path)
                continue
            }
            if !manager.fileExists(atPath: (path as NSString).deletingLastPathComponent) { return false }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

    /// Runs `body` holding every lock, taken in order and released in reverse.
    public static func with<T>(_ locks: [(path: String, stale: TimeInterval)], timeout: TimeInterval = 9, _ body: () throws -> T) throws -> T {
        let held = Held()
        // A live holder touches its lock every few seconds; one that does not is taken for dead and its lock stolen.
        let toucher = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        toucher.schedule(deadline: .now() + 2, repeating: 2)
        toucher.setEventHandler {
            for path in held.all { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path) }
        }
        toucher.resume()
        defer {
            toucher.cancel()
            for path in held.all.reversed() { rmdir(path) }
        }
        for lock in locks {
            guard acquire(lock.path, stale: lock.stale, timeout: timeout) else { throw Timeout() }
            held.add(lock.path)
        }
        return try body()
    }
}

/// Paths of the locks held by one `ClaudeLocks.with` call, shared with the timer that keeps them fresh.
private final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}
