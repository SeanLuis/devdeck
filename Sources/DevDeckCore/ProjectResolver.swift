import Foundation

public struct ProjectIdentity: Hashable, Codable, Sendable, Identifiable {
    public var id: String { root }
    public let root: String
    public let name: String

    public init(root: String, name: String) {
        self.root = root
        self.name = name
    }

    public static func named(root: String) -> ProjectIdentity {
        let url = URL(fileURLWithPath: root)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == ".worktrees" {
            return ProjectIdentity(root: root, name: "\(parent.deletingLastPathComponent().lastPathComponent) ⎇ \(url.lastPathComponent)")
        }
        return ProjectIdentity(root: root, name: url.lastPathComponent)
    }
}

/// Maps any path (cwd, script path…) to the project that contains it.
/// A project root is the nearest directory with `.git`; otherwise the nearest one with a manifest.
public final class ProjectResolver: @unchecked Sendable {
    public static let manifests = ["package.json", "pnpm-workspace.yaml", "Cargo.toml", "pyproject.toml", "go.mod",
                                   "Gemfile", "composer.json", "requirements.txt", "deno.json", "Package.swift", "mix.exs"]

    private let lock = NSLock()
    private var cache: [String: ProjectIdentity?] = [:]
    private let home = NSHomeDirectory()
    private let fm = FileManager.default

    public init() {}

    public func isExcluded(_ path: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return true }
        let rel = path.dropFirst(home.count + 1)
        return rel.hasPrefix("Library/") || rel.hasPrefix(".") || rel == "Library"
    }

    public func resolve(path raw: String) -> ProjectIdentity? {
        var path = (raw as NSString).standardizingPath
        if let range = path.range(of: "/node_modules") { path = String(path[..<range.lowerBound]) }
        guard !isExcluded(path) else { return nil }

        lock.lock()
        if let hit = cache[path] { lock.unlock(); return hit }
        lock.unlock()

        var dir = path
        var nearestManifest: String?
        var result: ProjectIdentity?
        while dir.count > home.count {
            if fm.fileExists(atPath: dir + "/.git") {
                result = .named(root: dir)
                break
            }
            if nearestManifest == nil, Self.manifests.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) {
                nearestManifest = dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        if result == nil, let manifest = nearestManifest { result = .named(root: manifest) }

        lock.lock()
        cache[path] = result
        lock.unlock()
        return result
    }

    /// Nearest directory with a package manifest, used to label an app inside a monorepo.
    public func appDir(for path: String, within root: String) -> String? {
        var dir = (path as NSString).standardizingPath
        if let range = dir.range(of: "/node_modules") { dir = String(dir[..<range.lowerBound]) }
        while dir.hasPrefix(root) {
            if Self.manifests.contains(where: { fm.fileExists(atPath: dir + "/" + $0) }) { return dir }
            if dir == root { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// Finds projects on disk (for projects that are not running right now).
public enum ProjectDiscovery {
    public static var defaultRoots: [String] {
        let home = NSHomeDirectory()
        return ["Documents", "Downloads", "Desktop", "Developer", "Projects", "code", "src", "dev", "repos", "work"]
            .map { "\(home)/\($0)" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static let skip: Set<String> = ["node_modules", "Library", "Pods", "DerivedData", "build", "dist", "target", "vendor", "venv"]

    public static func scan(roots: [String], maxDepth: Int = 5) -> [ProjectIdentity] {
        let fm = FileManager.default
        var found: [ProjectIdentity] = []
        var queue: [(String, Int)] = roots.map { ($0, 0) }
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            if fm.fileExists(atPath: dir + "/.git")
                || (depth > 0 && ProjectResolver.manifests.contains(where: { fm.fileExists(atPath: dir + "/" + $0) })) {
                found.append(.named(root: dir))
                // Worktrees live inside the repo; surface them as their own projects.
                let worktrees = dir + "/.worktrees"
                if let items = try? fm.contentsOfDirectory(atPath: worktrees) {
                    for item in items where !item.hasPrefix(".") { found.append(.named(root: "\(worktrees)/\(item)")) }
                }
                continue
            }
            guard depth < maxDepth, let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where !item.hasPrefix(".") && !skip.contains(item) && !item.hasSuffix(".app") {
                let child = dir + "/" + item
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    let values = try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])
                    if values?.isSymbolicLink == true || values?.isPackage == true { continue }
                    queue.append((child, depth + 1))
                }
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
