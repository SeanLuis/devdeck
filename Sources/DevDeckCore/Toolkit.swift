import Foundation

/// A maintenance command a developer would otherwise have to look up.
public struct ToolRecipe: Identifiable, Hashable, Sendable {
    public let id: String
    public let tool: String        // binary that must exist
    public let group: String
    public let title: String
    public let detail: String
    public let command: [String]
    public var destructive = false
    public var shell = false

    public init(id: String, tool: String, group: String, title: String, detail: String, command: [String], destructive: Bool = false, shell: Bool = false) {
        self.id = id; self.tool = tool; self.group = group; self.title = title; self.detail = detail
        self.command = command; self.destructive = destructive; self.shell = shell
    }

    public var commandLine: String { command.joined(separator: " ") }
}

public enum Toolkit {
    public static let builtin: [ToolRecipe] = [
        ToolRecipe(id: "docker-df", tool: "docker", group: "Docker", title: "Ver qué ocupa espacio", detail: "Imágenes, contenedores, volúmenes y caché de build.", command: ["docker", "system", "df"]),
        ToolRecipe(id: "docker-containers", tool: "docker", group: "Docker", title: "Borrar contenedores detenidos", detail: "No toca los que están corriendo ni los volúmenes.", command: ["docker", "container", "prune", "-f"], destructive: true),
        ToolRecipe(id: "docker-images", tool: "docker", group: "Docker", title: "Borrar imágenes sin usar", detail: "Las que ningún contenedor usa; se vuelven a descargar si hacen falta.", command: ["docker", "image", "prune", "-a", "-f"], destructive: true),
        ToolRecipe(id: "docker-builder", tool: "docker", group: "Docker", title: "Vaciar la caché de build", detail: "Capas intermedias de docker build.", command: ["docker", "builder", "prune", "-a", "-f"], destructive: true),
        ToolRecipe(id: "docker-volumes", tool: "docker", group: "Docker", title: "Borrar volúmenes huérfanos", detail: "Cuidado: puede incluir datos de bases de datos de proyectos viejos.", command: ["docker", "volume", "prune", "-f"], destructive: true),
        ToolRecipe(id: "docker-stop", tool: "docker", group: "Docker", title: "Detener todos los contenedores", detail: "Libera la RAM que usan dentro de la VM; los datos se conservan.", command: ["docker ps -q | xargs -r docker stop"], destructive: true, shell: true),
        ToolRecipe(id: "npm-cache", tool: "npm", group: "Node", title: "npm: limpiar caché", detail: "~/.npm. Se vuelve a llenar al instalar.", command: ["npm", "cache", "clean", "--force"], destructive: true),
        ToolRecipe(id: "pnpm-prune", tool: "pnpm", group: "Node", title: "pnpm: podar el store", detail: "Quita paquetes que ningún proyecto usa ya.", command: ["pnpm", "store", "prune"], destructive: true),
        ToolRecipe(id: "bun-cache", tool: "bun", group: "Node", title: "bun: limpiar caché", detail: "Caché global de paquetes de Bun.", command: ["bun", "pm", "cache", "rm"], destructive: true),
        ToolRecipe(id: "yarn-cache", tool: "yarn", group: "Node", title: "yarn: limpiar caché", detail: "Caché global de Yarn.", command: ["yarn", "cache", "clean"], destructive: true),
        ToolRecipe(id: "uv-prune", tool: "uv", group: "Python", title: "uv: podar caché", detail: "Solo entradas que ya no se usan.", command: ["uv", "cache", "prune"], destructive: true),
        ToolRecipe(id: "uv-clean", tool: "uv", group: "Python", title: "uv: vaciar caché", detail: "Todo; se vuelve a descargar al sincronizar.", command: ["uv", "cache", "clean"], destructive: true),
        ToolRecipe(id: "pip-purge", tool: "pip3", group: "Python", title: "pip: vaciar caché", detail: "Ruedas y descargas de pip.", command: ["pip3", "cache", "purge"], destructive: true),
        ToolRecipe(id: "gradle-stop", tool: "pkill", group: "Java", title: "Detener daemons de Gradle", detail: "Procesos java que Gradle deja vivos consumiendo RAM. Se relanzan solos al compilar.", command: ["pkill", "-f", "GradleDaemon"], destructive: true),
        ToolRecipe(id: "kotlin-stop", tool: "pkill", group: "Java", title: "Detener daemons de Kotlin", detail: "Compilador Kotlin en segundo plano.", command: ["pkill", "-f", "KotlinCompileDaemon"], destructive: true),
        ToolRecipe(id: "gradle-cache", tool: "rm", group: "Java", title: "Borrar caché de Gradle", detail: "~/.gradle/caches. La próxima compilación descarga dependencias.", command: ["rm -rf ~/.gradle/caches"], destructive: true, shell: true),
        ToolRecipe(id: "brew-cleanup", tool: "brew", group: "Sistema", title: "Homebrew: limpiar", detail: "Versiones viejas y descargas.", command: ["brew", "cleanup", "-s", "--prune=all"], destructive: true),
        ToolRecipe(id: "brew-autoremove", tool: "brew", group: "Sistema", title: "Homebrew: quitar dependencias sin uso", detail: "Fórmulas que ya nadie necesita.", command: ["brew", "autoremove"], destructive: true),
        ToolRecipe(id: "xcode-derived", tool: "rm", group: "Sistema", title: "Xcode: borrar DerivedData", detail: "Builds intermedios; Xcode los regenera.", command: ["rm -rf ~/Library/Developer/Xcode/DerivedData/*"], destructive: true, shell: true),
        ToolRecipe(id: "simctl", tool: "xcrun", group: "Sistema", title: "Borrar simuladores no disponibles", detail: "Simuladores de versiones de iOS que ya no tienes.", command: ["xcrun", "simctl", "delete", "unavailable"], destructive: true),
    ]

    /// Your own recipes: `toolkit.json` in DevDeck's data folder, read again whenever the file changes.
    ///
    ///     [{"tool": "docker", "group": "Docker", "title": "Reiniciar el proxy", "detail": "…",
    ///       "command": ["docker", "restart", "proxy"], "destructive": true}]
    ///
    /// `command` is the argument list; with `"shell": true` it is one line run by the shell.
    nonisolated(unsafe) public static var customURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("DevDeck/toolkit.json")
    nonisolated(unsafe) private static var cache: (modified: Date, recipes: [ToolRecipe])?
    private static let cacheLock = NSLock()

    public static func parseCustom(_ data: Data) -> [ToolRecipe] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.enumerated().compactMap { index, item in
            guard let title = item["title"] as? String, let command = item["command"] as? [String], let first = command.first, !first.isEmpty else { return nil }
            let shell = item["shell"] as? Bool ?? false
            let tool = item["tool"] as? String ?? (shell ? "sh" : first)
            return ToolRecipe(id: "custom-" + (item["id"] as? String ?? String(index)), tool: tool, group: item["group"] as? String ?? "Propias",
                              title: title, detail: item["detail"] as? String ?? command.joined(separator: " "), command: command,
                              // Unknown commands ask before running unless the file says they are harmless.
                              destructive: item["destructive"] as? Bool ?? true, shell: shell)
        }
    }

    public static var custom: [ToolRecipe] {
        guard let url = customURL, let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return [] }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, cache.modified == modified { return cache.recipes }
        let recipes = (try? Data(contentsOf: url)).map(parseCustom) ?? []
        cache = (modified, recipes)
        return recipes
    }

    public static var recipes: [ToolRecipe] { builtin + custom }

    public static func recipe(_ id: String) -> ToolRecipe? { recipes.first { $0.id == id } }

    /// Recipes whose tool exists on this Mac.
    public static func available(env: [String: String]) -> [ToolRecipe] {
        recipes.filter { LoginEnvironment.which($0.tool, env: env) != nil }
    }
}

/// Docker Desktop keeps the size of its Linux VM in a JSON settings file; lowering it is the only way to really cap Docker's RAM.
public enum DockerDesktop {
    public static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Group Containers/group.com.docker/settings-store.json")
    }

    public static func memoryMiB(settings url: URL = settingsURL) -> Int? {
        guard let data = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["MemoryMiB"] as? NSNumber)?.intValue
    }

    /// Writes the new VM size, keeping every other setting. Docker Desktop applies it on its next start.
    public static func setMemoryMiB(_ value: Int, settings url: URL = settingsURL) throws {
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        obj["MemoryMiB"] = value
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }
}
