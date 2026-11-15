import Foundation

/// One service a project declares in its `devdeck.json`.
public struct ManifestService: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    /// What to run, as it would be typed in the project's folder.
    public var command: String
    /// Folder to run it in, relative to the project; the project's own folder when absent.
    public var dir: String?
    public var port: UInt16?
    /// Where to ask whether it answers: a path ("/healthz") on its port, or a whole URL.
    public var health: String?

    public init(name: String, command: String, dir: String? = nil, port: UInt16? = nil, health: String? = nil) {
        self.name = name; self.command = command; self.dir = dir; self.port = port; self.health = health
    }
}

/// A project's infrastructure, declared in a `devdeck.json` at its root so it can be committed and shared:
/// the services to run and the compose file with what they depend on. It holds no environment: secrets stay out.
public struct ProjectManifest: Codable, Hashable, Sendable {
    public static let fileName = "devdeck.json"

    public var services: [ManifestService]
    /// Compose file, relative to the project. Found by its usual names when absent.
    public var compose: String?

    public init(services: [ManifestService] = [], compose: String? = nil) { self.services = services; self.compose = compose }

    public static func path(root: String) -> String { root + "/" + fileName }

    /// nil when the project has no manifest; throws when it has one that cannot be read.
    public static func load(root: String) throws -> ProjectManifest? {
        guard let data = FileManager.default.contents(atPath: path(root: root)) else { return nil }
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        // Names identify services on screen: empty or repeated ones are dropped rather than guessed.
        var seen = Set<String>()
        manifest.services = manifest.services.filter { !$0.name.isEmpty && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0.name).inserted }
        return manifest
    }

    public func save(root: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(self) + Data([0x0A])).write(to: URL(fileURLWithPath: Self.path(root: root)), options: .atomic)
    }

    /// A manifest written from what DevDeck remembers of the project: commands, folders and ports. Never the environment.
    public static func from(recipes: [LaunchRecipe], root: String, composeFile: String?) -> ProjectManifest {
        var services: [ManifestService] = []
        var ports = Set<UInt16>(), names = Set<String>()
        for recipe in recipes {
            // Two remembered variants of the same server: the most recent one is the project's.
            if let port = recipe.ports.first, !ports.insert(port).inserted { continue }
            var name = recipe.label.isEmpty ? (recipe.argv.first ?? "service") : recipe.label
            if !names.insert(name).inserted, let port = recipe.ports.first { name += "-\(port)"; names.insert(name) }
            let dir = recipe.cwd == root ? nil : recipe.cwd.hasPrefix(root + "/") ? String(recipe.cwd.dropFirst(root.count + 1)) : recipe.cwd
            services.append(ManifestService(name: name, command: recipe.argv.map(ProcessControl.shellQuote).joined(separator: " "), dir: dir, port: recipe.ports.first))
        }
        let compose = composeFile.map { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : $0 }
        return ProjectManifest(services: services, compose: compose)
    }

    public func composeFile(root: String) -> String? {
        if let compose {
            let path = compose.hasPrefix("/") ? compose : root + "/" + compose
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        return ProjectStart.composeFile(in: root)
    }

    public func folder(of service: ManifestService, root: String) -> String {
        guard let dir = service.dir, !dir.isEmpty else { return root }
        return dir.hasPrefix("/") ? dir : ((root + "/" + dir) as NSString).standardizingPath
    }

    /// The command as something DevDeck can start. Plain commands run as they are; anything a shell must read
    /// (pipes, &&, variables) goes through the login shell.
    public func recipe(for service: ManifestService, root: String) -> LaunchRecipe {
        let plain = service.command.range(of: #"^[A-Za-z0-9_@%+=:,./\- ]+$"#, options: .regularExpression) != nil
        let argv = plain ? service.command.split(separator: " ").map(String.init) : ["/bin/zsh", "-l", "-c", service.command]
        return LaunchRecipe(projectRoot: root, cwd: folder(of: service, root: root), argv: argv, env: [:], label: service.name,
                            ports: service.port.map { [$0] } ?? [])
    }

    public func recipes(root: String) -> [LaunchRecipe] { services.map { recipe(for: $0, root: root) } }

    public func healthURL(of service: ManifestService) -> URL? {
        guard let health = service.health, !health.isEmpty else { return nil }
        if health.hasPrefix("http://") || health.hasPrefix("https://") { return URL(string: health) }
        guard let port = service.port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)" + (health.hasPrefix("/") ? health : "/" + health))
    }
}

/// Whether a declared service is there and answering.
public enum ServiceHealth: Hashable, Sendable {
    /// Not running.
    case down
    /// Running; nothing more is known (no port or no health address declared).
    case running
    /// Its health address answered well.
    case healthy
    /// Running, but its health address fails or answers with a server error.
    case failing(String)

    public var isUp: Bool { self != .down }
}

public enum ProjectHealth {
    /// Running or not, from what the Mac shows: its port is listened on, or a live service runs it in its folder.
    public static func isRunning(_ service: ManifestService, manifest: ProjectManifest, root: String, services: [ServiceInfo], boundPorts: Set<UInt16>) -> Bool {
        ProjectStart.isRunning(manifest.recipe(for: service, root: root), services: services, boundPorts: boundPorts)
    }

    /// Asks a health address once. Anything below 500 counts as answering: a login page or a 404 still means the server is up.
    public static func ask(_ url: URL, timeout: TimeInterval = 2.5) async -> ServiceHealth {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        do {
            let (_, response) = try await URLSession(configuration: config).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status < 500 ? .healthy : .failing("HTTP \(status)")
        } catch {
            return .failing((error as? URLError)?.code == .timedOut ? "timeout" : "no answer")
        }
    }

    public static func check(_ manifest: ProjectManifest, root: String, services: [ServiceInfo], boundPorts: Set<UInt16>) async -> [String: ServiceHealth] {
        var out: [String: ServiceHealth] = [:]
        for service in manifest.services {
            guard isRunning(service, manifest: manifest, root: root, services: services, boundPorts: boundPorts) else { out[service.name] = .down; continue }
            if let url = manifest.healthURL(of: service) { out[service.name] = await ask(url) } else { out[service.name] = .running }
        }
        return out
    }
}
