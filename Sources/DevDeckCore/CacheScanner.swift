import Foundation

public enum CacheKind: String, Codable, Sendable, CaseIterable {
    case buildCache, dependencies, buildOutput, virtualEnv, toolCache, agentData, appData

    public var title: String {
        switch self {
        case .buildCache: return L("Caché de build")
        case .dependencies: return L("Dependencias")
        case .buildOutput: return L("Salida de build")
        case .virtualEnv: return L("Entorno virtual")
        case .toolCache: return L("Caché de herramienta")
        case .agentData: return L("Datos de agentes")
        case .appData: return L("Datos de apps")
        }
    }
}

public enum CleanMethod: Codable, Sendable, Hashable {
    case deleteDirectory
    case deleteContents
    case command([String])
    case deleteFilesOlderThan(days: Int, extensions: [String])
}

public struct CacheEntry: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let label: String
    public let kind: CacheKind
    public var sizeBytes: UInt64
    public let projectRoot: String?
    public let note: String
    public let regenerate: String
    public let method: CleanMethod
    /// Regenerable without losing work (safe for automation).
    public let safe: Bool

    public var relativePath: String {
        guard let root = projectRoot, path.hasPrefix(root) else { return Fmt.tilde(path) }
        let rel = path.dropFirst(root.count)
        return rel.isEmpty ? "." : String(rel.dropFirst())
    }
}

public enum CacheScanner {
    struct Pattern {
        let name: String
        let kind: CacheKind
        let note: String
        let safe: Bool
        let requires: [String]   // sibling files that must exist (any)
    }

    static let patterns: [Pattern] = [
        Pattern(name: ".next", kind: .buildCache, note: "Build y caché de Next.js", safe: true, requires: []),
        Pattern(name: ".turbo", kind: .buildCache, note: "Caché de Turborepo", safe: true, requires: []),
        Pattern(name: ".vite", kind: .buildCache, note: "Caché de Vite", safe: true, requires: []),
        Pattern(name: ".parcel-cache", kind: .buildCache, note: "Caché de Parcel", safe: true, requires: []),
        Pattern(name: ".svelte-kit", kind: .buildCache, note: "Build de SvelteKit", safe: true, requires: []),
        Pattern(name: ".nuxt", kind: .buildCache, note: "Build de Nuxt", safe: true, requires: []),
        Pattern(name: ".output", kind: .buildOutput, note: "Salida de Nitro/Nuxt", safe: true, requires: ["package.json"]),
        Pattern(name: ".angular", kind: .buildCache, note: "Caché de Angular", safe: true, requires: []),
        Pattern(name: ".expo", kind: .buildCache, note: "Caché de Expo", safe: true, requires: []),
        Pattern(name: ".astro", kind: .buildCache, note: "Caché de Astro", safe: true, requires: []),
        Pattern(name: ".docusaurus", kind: .buildCache, note: "Caché de Docusaurus", safe: true, requires: []),
        Pattern(name: ".wrangler", kind: .buildCache, note: "Estado local de Wrangler", safe: false, requires: []),
        Pattern(name: "storybook-static", kind: .buildOutput, note: "Build de Storybook", safe: true, requires: []),
        Pattern(name: "coverage", kind: .buildOutput, note: "Reportes de cobertura", safe: true, requires: ["package.json"]),
        Pattern(name: ".pytest_cache", kind: .buildCache, note: "Caché de pytest", safe: true, requires: []),
        Pattern(name: ".mypy_cache", kind: .buildCache, note: "Caché de mypy", safe: true, requires: []),
        Pattern(name: ".ruff_cache", kind: .buildCache, note: "Caché de ruff", safe: true, requires: []),
        Pattern(name: "dist", kind: .buildOutput, note: "Salida de build", safe: false, requires: ["package.json"]),
        Pattern(name: "target", kind: .buildCache, note: "Build de Rust (cargo)", safe: true, requires: ["Cargo.toml"]),
        Pattern(name: ".gradle", kind: .buildCache, note: "Caché de Gradle", safe: true, requires: []),
        Pattern(name: "node_modules", kind: .dependencies, note: "Dependencias instaladas", safe: false, requires: ["package.json"]),
        Pattern(name: ".venv", kind: .virtualEnv, note: "Entorno virtual de Python", safe: false, requires: []),
        Pattern(name: "venv", kind: .virtualEnv, note: "Entorno virtual de Python", safe: false, requires: ["requirements.txt", "pyproject.toml"]),
    ]

    static let byName: [String: Pattern] = Dictionary(uniqueKeysWithValues: patterns.map { ($0.name, $0) })
    static let neverDescend: Set<String> = Set(patterns.map(\.name)).union([".git", "Pods", "DerivedData", "__pycache__", ".worktrees"])

    /// Finds cache directories inside a project (monorepo-aware, depth-limited).
    public static func findCaches(projectRoot: String, maxDepth: Int = 4) -> [(path: String, pattern: String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        var queue: [(String, Int)] = [(projectRoot, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let itemSet = Set(items)
            for item in items {
                let path = dir + "/" + item
                if let pattern = byName[item] {
                    if pattern.requires.isEmpty || pattern.requires.contains(where: itemSet.contains) {
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { out.append((path, item)) }
                    }
                    continue
                }
                guard depth < maxDepth, !neverDescend.contains(item) else { continue }
                if item.hasPrefix(".") { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                queue.append((path, depth + 1))
            }
        }
        return out
    }

    public static func regenerateHint(for pattern: String, dir: String, projectRoot: String) -> String {
        switch pattern {
        case "node_modules":
            let pm = PackageScripts.packageManager(dir: dir, projectRoot: projectRoot)
            return pm == "npm" ? "npm ci" : "\(pm) install"
        case ".venv", "venv": return "uv sync / pip install -r requirements.txt"
        case "target": return "cargo build"
        case "dist", ".output", "storybook-static", "coverage": return "Se vuelve a generar con el build"
        default: return "Se regenera solo en el próximo dev/build"
        }
    }

    /// Size on disk in bytes (du is far faster than walking node_modules from Swift).
    public static func size(of path: String) async -> UInt64 {
        let r = await Shell.run("/usr/bin/du", ["-sk", path], timeout: 120)
        guard let kb = r.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ UInt64($0) }) else { return 0 }
        return kb * 1024
    }

    public static func scanProject(_ project: ProjectIdentity) async -> [CacheEntry] {
        let found = findCaches(projectRoot: project.root)
        var entries: [CacheEntry] = []
        for (path, name) in found {
            guard let pattern = byName[name] else { continue }
            let bytes = await size(of: path)
            guard bytes > 1_048_576 else { continue }  // ignore < 1 MB
            let dir = (path as NSString).deletingLastPathComponent
            entries.append(CacheEntry(path: path, label: name, kind: pattern.kind, sizeBytes: bytes, projectRoot: project.root,
                                      note: pattern.note, regenerate: regenerateHint(for: name, dir: dir, projectRoot: project.root),
                                      method: .deleteDirectory, safe: pattern.safe))
        }
        return entries.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: - Global caches

    public struct GlobalDefinition: Sendable {
        let path: String
        let label: String
        let kind: CacheKind
        let note: String
        let regenerate: String
        let method: CleanMethod
        let safe: Bool
    }

    public static var globalDefinitions: [GlobalDefinition] {
        let h = NSHomeDirectory()
        return [
            .init(path: "\(h)/.npm/_cacache", label: "npm", kind: .toolCache, note: "Caché de paquetes npm", regenerate: "Se descarga de nuevo al instalar", method: .command(["npm", "cache", "clean", "--force"]), safe: true),
            .init(path: "\(h)/Library/pnpm/store", label: "pnpm store", kind: .toolCache, note: "Store global de pnpm (prune quita lo que ningún proyecto usa)", regenerate: "pnpm install", method: .command(["pnpm", "store", "prune"]), safe: true),
            .init(path: "\(h)/Library/Caches/pnpm", label: "pnpm (metadata)", kind: .toolCache, note: "Metadata de pnpm", regenerate: "Automático", method: .deleteContents, safe: true),
            .init(path: "\(h)/.bun/install/cache", label: "Bun", kind: .toolCache, note: "Caché de paquetes de Bun", regenerate: "bun install", method: .command(["bun", "pm", "cache", "rm"]), safe: true),
            .init(path: "\(h)/Library/Caches/Yarn", label: "Yarn", kind: .toolCache, note: "Caché de Yarn", regenerate: "yarn install", method: .deleteContents, safe: true),
            .init(path: "\(h)/.cache/uv", label: "uv", kind: .toolCache, note: "Caché de uv (Python)", regenerate: "uv sync", method: .command(["uv", "cache", "clean"]), safe: true),
            .init(path: "\(h)/Library/Caches/pip", label: "pip", kind: .toolCache, note: "Caché de pip", regenerate: "pip install", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Caches/Homebrew", label: "Homebrew", kind: .toolCache, note: "Descargas viejas de Homebrew", regenerate: "brew install", method: .command(["brew", "cleanup", "-s", "--prune=all"]), safe: true),
            .init(path: "\(h)/Library/Caches/node-gyp", label: "node-gyp", kind: .toolCache, note: "Headers de Node para módulos nativos", regenerate: "Automático", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Caches/go-build", label: "Go build", kind: .toolCache, note: "Caché de compilación de Go", regenerate: "go build", method: .deleteContents, safe: true),
            .init(path: "\(h)/.cargo/registry", label: "Cargo registry", kind: .toolCache, note: "Crates descargados", regenerate: "cargo build", method: .deleteContents, safe: true),
            .init(path: "\(h)/.gradle/caches", label: "Gradle", kind: .toolCache, note: "Caché de Gradle", regenerate: "Gradle build", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Developer/Xcode/DerivedData", label: "Xcode DerivedData", kind: .toolCache, note: "Builds intermedios de Xcode", regenerate: "Rebuild en Xcode", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Developer/CoreSimulator", label: "Simuladores iOS", kind: .toolCache, note: "Borra solo simuladores no disponibles", regenerate: "—", method: .command(["xcrun", "simctl", "delete", "unavailable"]), safe: true),
            .init(path: "\(h)/Library/Caches/ms-playwright", label: "Playwright", kind: .toolCache, note: "Navegadores de Playwright", regenerate: "npx playwright install", method: .deleteContents, safe: true),
            .init(path: "\(h)/.cache/puppeteer", label: "Puppeteer", kind: .toolCache, note: "Navegadores de Puppeteer", regenerate: "Se descarga al usarlo", method: .deleteContents, safe: true),
            .init(path: "\(h)/.cache/huggingface", label: "Hugging Face", kind: .toolCache, note: "Modelos descargados (pesados de volver a bajar)", regenerate: "Se descargan de nuevo", method: .deleteContents, safe: false),
            .init(path: "\(h)/.claude/projects", label: "Claude Code — transcripts", kind: .agentData, note: "Historial de sesiones; borra las de más de 14 días", regenerate: "No se regenera (historial)", method: .deleteFilesOlderThan(days: 14, extensions: ["jsonl"]), safe: false),
            .init(path: "\(h)/.codex/sessions", label: "Codex — sesiones", kind: .agentData, note: "Historial de Codex; borra las de más de 14 días", regenerate: "No se regenera (historial)", method: .deleteFilesOlderThan(days: 14, extensions: ["jsonl"]), safe: false),
            .init(path: "\(h)/.local/share/devin/cli/logs", label: "Devin — logs", kind: .agentData, note: "Logs del CLI de Devin", regenerate: "—", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Application Support/Devin/logs", label: "Devin (app) — logs", kind: .agentData, note: "Logs de la app Devin", regenerate: "—", method: .deleteContents, safe: true),
            .init(path: "\(h)/Library/Application Support/Devin/CachedData", label: "Devin (app) — caché", kind: .agentData, note: "Caché de la app Devin", regenerate: "Automático", method: .deleteContents, safe: true),
            .init(path: "\(h)/.Trash", label: "Papelera", kind: .appData, note: "Archivos en la papelera", regenerate: "No se recupera", method: .deleteContents, safe: false),
        ]
    }

    public static func scanGlobal() async -> [CacheEntry] {
        var entries: [CacheEntry] = []
        for def in globalDefinitions where FileManager.default.fileExists(atPath: def.path) {
            let bytes = await size(of: def.path)
            guard bytes > 10 * 1_048_576 else { continue }
            entries.append(CacheEntry(path: def.path, label: def.label, kind: def.kind, sizeBytes: bytes, projectRoot: nil,
                                      note: def.note, regenerate: def.regenerate, method: def.method, safe: def.safe))
        }
        return entries.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Performs the cleanup. Returns a human summary.
    public static func clean(_ entry: CacheEntry, env: [String: String]) async -> String {
        let fm = FileManager.default
        switch entry.method {
        case .deleteDirectory:
            do { try fm.removeItem(atPath: entry.path); return L("Borrado %@ (%@)", L(entry.label), Fmt.bytes(entry.sizeBytes)) }
            catch { return L("No se pudo borrar %@: %@", L(entry.label), error.localizedDescription) }
        case .deleteContents:
            let items = (try? fm.contentsOfDirectory(atPath: entry.path)) ?? []
            var failures = 0
            for item in items { do { try fm.removeItem(atPath: entry.path + "/" + item) } catch { failures += 1 } }
            return failures == 0 ? L("Vaciado %@", L(entry.label)) : L("Vaciado %@ con %@ errores", L(entry.label), "\(failures)")
        case .command(let argv):
            guard let exe = LoginEnvironment.which(argv[0], env: env) else { return L("No encuentro '%@' para limpiar %@", argv[0], L(entry.label)) }
            let r = await Shell.run(exe, Array(argv.dropFirst()), env: env, timeout: 600)
            return r.ok ? L("Limpio: %@", L(entry.label)) : L("Falló %@: %@", argv.joined(separator: " "), String(r.stderr.prefix(200)))
        case .deleteFilesOlderThan(let days, let extensions):
            let removed = deleteFiles(in: entry.path, olderThanDays: days, extensions: extensions)
            return L("Borrados %@ archivos de más de %@ días en %@", "\(removed)", "\(days)", L(entry.label))
        }
    }

    static func deleteFiles(in path: String, olderThanDays days: Int, extensions: [String]) -> Int {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var removed = 0
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return 0 }
        while let url = walker.nextObject() as? URL {
            guard extensions.contains(url.pathExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let date = values?.contentModificationDate, date < cutoff,
               (try? fm.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }
}
