import Foundation

public enum GroupKind: String, Codable, Sendable, CaseIterable {
    case project, agent, headless, browser, docker, app, other, system

    public var title: String {
        switch self {
        case .project: return L("Proyectos")
        case .agent: return L("Agentes de IA")
        case .headless: return L("Navegadores headless")
        case .browser: return L("Navegadores")
        case .docker: return "Docker / VMs"
        case .app: return "Apps"
        case .other: return L("Otros procesos")
        case .system: return L("Sistema")
        }
    }

    public var symbol: String {
        switch self {
        case .project: return "folder.fill"
        case .agent: return "sparkles"
        case .headless: return "rectangle.stack.badge.play"
        case .browser: return "globe"
        case .docker: return "shippingbox.fill"
        case .app: return "app.fill"
        case .other: return "terminal.fill"
        case .system: return "apple.logo"
        }
    }
}

public struct ServiceInfo: Sendable, Hashable, Identifiable {
    public var id: Int32 { rootPid }
    public let rootPid: Int32
    public let label: String
    public let command: String
    public let cwd: String?
    public let appDir: String?
    /// Working directories of every process in the tree (a `pnpm --filter` root runs at the repo root,
    /// its next-server child inside apps/x).
    public let dirs: [String]
    public let framework: String?
    public let ports: [UInt16]
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public let pids: [Int32]
    public let startTime: Date
}

public struct PortBinding: Sendable, Hashable, Identifiable {
    public var id: String { "\(port)|\(pid)|\(address)" }
    public let port: UInt16
    public let address: String
    public let pid: Int32
    public let processName: String
    public var groupID: String
    public var groupName: String
    public var groupKind: GroupKind
    public var projectRoot: String?
    public var framework: String?
    public var container: String?
    public var serviceRootPid: Int32?
    public var memoryBytes: UInt64
    public var cpuPercent: Double
    public var startTime: Date

    public var isLoopbackOnly: Bool { address == "127.0.0.1" || address == "::1" }
    public var url: URL? { URL(string: "http://localhost:\(port)") }
}

public struct ProcessGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: GroupKind
    public let name: String
    public let detail: String
    public let projectRoot: String?
    public let pids: [Int32]
    public let memoryBytes: UInt64
    public let cpuPercent: Double
    public var ports: [PortBinding]
    public let services: [ServiceInfo]
    public var containers: [ContainerInfo]
    public let frameworks: [String]
    /// For headless browsers: who launched them (agent/app/project name → count of browser roots).
    public let origins: [String: Int]
    /// Estimated compressed/swapped memory of the group (footprint not resident in RAM).
    public var offloadedBytes: UInt64 = 0
    /// Bytes/s the group is reading back from disk.
    public var pageInRate: Double = 0

    public var processCount: Int { pids.count }
    public var killable: Bool { kind != .system && id != Classifier.selfGroupID }
    public var containerMemory: UInt64 { containers.reduce(0) { $0 + ($1.memoryBytes ?? 0) } }
}

public struct Snapshot: Sendable {
    public let time: Date
    public let processes: [Int32: ProcessRecord]
    public let groups: [ProcessGroup]
    public let ports: [PortBinding]
    public let containers: [ContainerInfo]
    public let pidToGroup: [Int32: String]

    public static let empty = Snapshot(time: Date(), processes: [:], groups: [], ports: [], containers: [], pidToGroup: [:])

    public func group(_ id: String) -> ProcessGroup? { groups.first { $0.id == id } }
    public func group(forPid pid: Int32) -> ProcessGroup? {
        guard let id = pidToGroup[pid] else { return nil }
        return group(id)
    }
    public func group(forProject root: String) -> ProcessGroup? { group("project:\(root)") }

    public func service(rootPid: Int32) -> (ProcessGroup, ServiceInfo)? {
        for g in groups { if let s = g.services.first(where: { $0.rootPid == rootPid }) { return (g, s) } }
        return nil
    }

    public func service(containing pid: Int32) -> (ProcessGroup, ServiceInfo)? {
        guard let g = group(forPid: pid) else { return nil }
        if let s = g.services.first(where: { $0.pids.contains(pid) }) { return (g, s) }
        return nil
    }

    public var headlessBrowserCount: Int {
        guard let g = group(Classifier.headlessID) else { return 0 }
        return g.origins.values.reduce(0, +)
    }
}

/// Decides "where does this load come from" for every process.
public struct Classifier {
    public static let selfGroupID = "app:DevDeck"
    public static let headlessID = "headless"
    public static let dockerID = "docker"
    public static let systemID = "system"

    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "dash", "login", "tmux", "screen", "nu", "tcsh"]
    static let browsers: Set<String> = ["Google Chrome", "Brave Browser", "Safari", "Firefox", "Arc", "Microsoft Edge", "Chromium",
                                        "Opera", "Opera GX", "Vivaldi", "Zen Browser", "Zen", "Dia", "Orion"]
    static let agentApps: Set<String> = ["Devin", "Claude", "Cursor", "Windsurf", "Codex", "ChatGPT", "Kiro", "Trae"]

    /// Identity is the `id` only, so processes with different paths but the same group id merge.
    struct GroupKey: Hashable {
        let id: String
        let kind: GroupKind
        let name: String
        let detail: String
        let root: String?

        static func == (a: GroupKey, b: GroupKey) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum Direct {
        case group(GroupKey)
        case shell
        case unknown
    }

    let resolver: ProjectResolver
    let myUID: UInt32
    let selfPid: Int32
    let home = NSHomeDirectory()

    static var headlessKey: GroupKey { GroupKey(id: headlessID, kind: .headless, name: "Chrome headless", detail: L("Navegadores sin ventana (tests, scraping, capturas)"), root: nil) }
    static var dockerKey: GroupKey { GroupKey(id: dockerID, kind: .docker, name: "Docker", detail: L("Docker Desktop + VM de Linux"), root: nil) }
    static var systemKey: GroupKey { GroupKey(id: systemID, kind: .system, name: L("macOS y sistema"), detail: L("Procesos del sistema y de otros usuarios"), root: nil) }

    public init(resolver: ProjectResolver, myUID: UInt32, selfPid: Int32) {
        self.resolver = resolver
        self.myUID = myUID
        self.selfPid = selfPid
    }

    // MARK: - Direct classification

    func direct(_ p: ProcessRecord) -> Direct {
        if p.pid == selfPid {
            return .group(GroupKey(id: Self.selfGroupID, kind: .app, name: "DevDeck", detail: L("Este panel"), root: nil))
        }
        let exe = p.executablePath
        let exeName = (exe as NSString).lastPathComponent
        if Self.isHeadlessBrowser(exe: exe, args: p.args) { return .group(Self.headlessKey) }
        if let agent = Self.agentName(exe: exe, exeName: exeName, args: p.args) {
            return .group(GroupKey(id: "agent:\(agent)", kind: .agent, name: agent, detail: L("Agente de IA"), root: nil))
        }
        if exe.contains("com.apple.Virtualization.VirtualMachine") || exe.contains("/OrbStack.app/") {
            return .group(Self.dockerKey)
        }
        // System and other users' processes first, so Finder, Dock, Terminal… are never killable.
        if p.uid != myUID || exe.hasPrefix("/System/") || exe.hasPrefix("/usr/libexec/") || exe.hasPrefix("/usr/sbin/")
            || exe.hasPrefix("/sbin/") || exe.hasPrefix("/Library/Apple/") || exe.isEmpty {
            return .group(Self.systemKey)
        }
        if let app = Self.appBundleName(exe) {
            if app == "Docker" { return .group(Self.dockerKey) }
            let kind: GroupKind = Self.browsers.contains(app) ? .browser : .app
            return .group(GroupKey(id: "app:\(app)", kind: kind, name: app, detail: Self.appBundlePath(exe) ?? exe, root: nil))
        }
        if Self.shells.contains(p.name) || Self.shells.contains(exeName) { return .shell }
        // MCP servers are agent tooling: let them inherit the agent that spawned them, not the project they sit in.
        if Self.isMCPServer(p.args) { return .unknown }
        if let project = projectFor(p) {
            return .group(GroupKey(id: "project:\(project.root)", kind: .project, name: project.name,
                                   detail: Fmt.tilde(project.root), root: project.root))
        }
        return .unknown
    }

    func projectFor(_ p: ProcessRecord) -> ProjectIdentity? {
        if let cwd = p.cwd, cwd != "/", cwd != home, let project = resolver.resolve(path: cwd) { return project }
        for arg in p.args.prefix(6) where arg.hasPrefix(home + "/") {
            if let project = resolver.resolve(path: arg) { return project }
        }
        if p.executablePath.hasPrefix(home + "/"), let project = resolver.resolve(path: p.executablePath) { return project }
        return nil
    }

    public static func isHeadlessBrowser(exe: String, args: [String]) -> Bool {
        let name = (exe as NSString).lastPathComponent.lowercased()
        if name.contains("headless_shell") || name.contains("chrome-headless-shell") { return true }
        guard name.contains("chrom") || name.contains("brave") || name.contains("edge") else { return false }
        return args.contains { $0.hasPrefix("--headless") }
    }

    public static func agentName(exe: String, exeName: String, args: [String]) -> String? {
        if let app = appBundleName(exe), agentApps.contains(app) { return app == "Claude" ? "Claude (app)" : app }
        switch exeName.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "devin": return "Devin"
        case "gemini": return "Gemini CLI"
        case "aider": return "Aider"
        case "opencode": return "OpenCode"
        case "cursor-agent": return "Cursor"
        case "goose": return "Goose"
        case "amp": return "Amp"
        default: break
        }
        let lowerExe = exe.lowercased()
        if lowerExe.contains("claude-agent-sdk") || lowerExe.contains("/claude-code/") || lowerExe.contains("/claude/versions/") {
            return "Claude Code"
        }
        if lowerExe.contains("/devin/") { return "Devin" }
        let joined = args.prefix(4).joined(separator: " ").lowercased()
        if joined.contains("claude-agent-acp") || joined.contains("@anthropic-ai/claude-code") || joined.contains("claude-agent-sdk")
            || joined.contains("/.claude/") { return "Claude Code" }
        if joined.contains("gemini-cli") { return "Gemini CLI" }
        if joined.contains("@openai/codex") || joined.contains("/.codex/") { return "Codex" }
        if joined.contains("opencode") { return "OpenCode" }
        return nil
    }

    public static func isMCPServer(_ args: [String]) -> Bool {
        let joined = args.prefix(6).joined(separator: " ").lowercased()
        return joined.hasSuffix(" mcp") || joined.contains(" mcp ") || joined.contains("mcp-server") || joined.contains("-mcp")
            || joined.contains("@modelcontextprotocol") || joined.contains("mcp_server") || joined.contains("/mcp/")
    }

    static func appBundlePath(_ exe: String) -> String? {
        guard let range = exe.range(of: ".app/") else { return nil }
        return String(exe[..<range.lowerBound]) + ".app"
    }

    public static func appBundleName(_ exe: String) -> String? {
        guard let path = appBundlePath(exe) else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public static func framework(for p: ProcessRecord) -> String? {
        let text = (p.args.prefix(6).joined(separator: " ") + " " + p.name).lowercased()
        let table: [(String, String)] = [
            ("next-server", "Next.js"), ("next dev", "Next.js"), ("next start", "Next.js"), ("/next/dist", "Next.js"),
            ("turbopack", "Turbopack"), ("vite", "Vite"), ("nuxt", "Nuxt"), ("astro", "Astro"), ("remix", "Remix"),
            ("react-router", "React Router"), ("svelte-kit", "SvelteKit"), ("expo start", "Expo"), ("storybook", "Storybook"),
            ("webpack", "Webpack"), ("wrangler", "Wrangler"), ("turbo ", "Turborepo"), ("@nestjs", "NestJS"),
            ("inngest", "Inngest"), ("supabase", "Supabase"), ("hardhat", "Hardhat"), ("anvil", "Anvil"),
            ("tsx", "tsx"), ("ts-node", "ts-node"), ("nodemon", "nodemon"), ("uvicorn", "Uvicorn"), ("gunicorn", "Gunicorn"),
            ("flask", "Flask"), ("manage.py", "Django"), ("streamlit", "Streamlit"), ("jupyter", "Jupyter"),
            ("rails", "Rails"), ("puma", "Puma"), ("cargo", "Cargo"), ("postgres", "PostgreSQL"), ("redis-server", "Redis"),
            ("mongod", "MongoDB"), ("java", "Java"), ("bun", "Bun"), ("deno", "Deno"), ("python", "Python"), ("node", "Node.js"),
        ]
        for (needle, name) in table where text.contains(needle) { return name }
        return nil
    }

    // MARK: - Build

    public func build(processes: [ProcessRecord], ports: [Int32: [RawListeningPort]], containers: [ContainerInfo], now: Date) -> Snapshot {
        var byPid: [Int32: ProcessRecord] = [:]
        for p in processes { byPid[p.pid] = p }
        var children: [Int32: [Int32]] = [:]
        for p in processes { children[p.ppid, default: []].append(p.pid) }

        func ancestors(_ pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var current = byPid[pid]?.ppid ?? 0
            while current > 1, out.count < 64, let p = byPid[current] {
                out.append(current)
                current = p.ppid
            }
            return out
        }

        var direct: [Int32: Direct] = [:]
        for p in processes { direct[p.pid] = self.direct(p) }
        // Children of MCP servers belong to the agent too, even if their cwd is inside a project.
        let mcpPids = Set(processes.filter { $0.isMine && Self.isMCPServer($0.args) }.map(\.pid))
        if !mcpPids.isEmpty {
            for p in processes {
                guard case .group(let key)? = direct[p.pid], key.kind == .project else { continue }
                if ancestors(p.pid).contains(where: mcpPids.contains) { direct[p.pid] = .unknown }
            }
        }

        var assigned: [Int32: GroupKey] = [:]
        for p in processes {
            guard case .group(let key)? = direct[p.pid] else { continue }
            // Helpers of a headless browser are bundled in the same Chrome.app; keep them in the headless group.
            if key.kind == .browser, ancestors(p.pid).contains(where: { assignedIsHeadless(direct[$0]) }) {
                assigned[p.pid] = Self.headlessKey
            } else {
                assigned[p.pid] = key
            }
        }
        for p in processes where assigned[p.pid] == nil {
            var key = ancestors(p.pid).lazy.compactMap { assigned[$0] }.first
            if key == nil {
                if p.uid != myUID {
                    key = Self.systemKey
                } else if case .shell? = direct[p.pid] {
                    key = GroupKey(id: "other:shells", kind: .other, name: L("Shells sueltos"), detail: L("zsh/bash sin terminal"), root: nil)
                } else {
                    key = GroupKey(id: "other:\(p.name)", kind: .other, name: p.name, detail: Fmt.tilde(p.executablePath), root: nil)
                }
            }
            assigned[p.pid] = key
        }

        // Containers → projects via the compose working dir label.
        var containerByPort: [UInt16: ContainerInfo] = [:]
        var containersByRoot: [String: [ContainerInfo]] = [:]
        for c in containers {
            if c.isRunning { for port in c.ports { containerByPort[port.hostPort] = c } }
            if let dir = c.workingDir, let project = resolver.resolve(path: dir) {
                containersByRoot[project.root, default: []].append(c)
            }
        }

        var members: [GroupKey: [Int32]] = [:]
        for (pid, key) in assigned { members[key, default: []].append(pid) }
        for (root, list) in containersByRoot where list.contains(where: \.isRunning) {
            let id = "project:\(root)"
            if !members.keys.contains(where: { $0.id == id }) {
                let identity = ProjectIdentity.named(root: root)
                members[GroupKey(id: id, kind: .project, name: identity.name, detail: Fmt.tilde(root), root: root)] = []
            }
        }
        if !containers.isEmpty, !members.keys.contains(where: { $0.id == Self.dockerID }) {
            members[Self.dockerKey] = []
        }

        var pidToGroup: [Int32: String] = [:]
        for (key, pids) in members { for pid in pids { pidToGroup[pid] = key.id } }

        // Services: top-level process trees inside a project group.
        var servicesByGroup: [String: [ServiceInfo]] = [:]
        var serviceRootOf: [Int32: Int32] = [:]
        for (key, pids) in members where key.kind == .project {
            let set = Set(pids)
            let roots = pids.filter { pid in !set.contains(byPid[pid]?.ppid ?? 0) }
            var services: [ServiceInfo] = []
            for root in roots {
                guard let rootProc = byPid[root] else { continue }
                var tree: [Int32] = []
                var stack = [root]
                while let pid = stack.popLast() {
                    guard set.contains(pid) else { continue }
                    tree.append(pid)
                    stack.append(contentsOf: children[pid] ?? [])
                }
                for pid in tree { serviceRootOf[pid] = root }
                let procs = tree.compactMap { byPid[$0] }
                let treePorts = Set(tree.flatMap { (ports[$0] ?? []).map(\.port) }).sorted()
                let framework = procs.lazy.compactMap { Self.framework(for: $0) }.first { $0 != "Node.js" && $0 != "Bun" }
                    ?? procs.lazy.compactMap { Self.framework(for: $0) }.first
                let cwd = rootProc.cwd ?? procs.lazy.compactMap(\.cwd).first
                let appDir = cwd.flatMap { dir in key.root.flatMap { resolver.appDir(for: dir, within: $0) } }
                var label = Fmt.shortCommand(rootProc.args.isEmpty ? [rootProc.name] : rootProc.args, max: 3)
                if let appDir, let root = key.root, appDir != root {
                    label += "  ·  " + String(appDir.dropFirst(root.count + 1))
                }
                services.append(ServiceInfo(
                    rootPid: root, label: label, command: rootProc.commandLine, cwd: cwd, appDir: appDir,
                    dirs: Array(Set(procs.compactMap(\.cwd))).sorted(),
                    framework: framework, ports: treePorts,
                    memoryBytes: procs.reduce(0) { $0 + $1.memoryBytes },
                    cpuPercent: procs.reduce(0) { $0 + $1.cpuPercent },
                    pids: tree, startTime: rootProc.startTime
                ))
            }
            servicesByGroup[key.id] = services.sorted { $0.memoryBytes > $1.memoryBytes }
        }

        // Ports
        var groupInfo: [String: GroupKey] = [:]
        for key in members.keys { groupInfo[key.id] = key }
        var bindings: [PortBinding] = []
        for (pid, list) in ports {
            guard let proc = byPid[pid], let gid = pidToGroup[pid], let key = groupInfo[gid] else { continue }
            for raw in list {
                var binding = PortBinding(
                    port: raw.port, address: raw.address, pid: pid, processName: proc.name,
                    groupID: gid, groupName: key.name, groupKind: key.kind, projectRoot: key.root,
                    framework: Self.framework(for: proc), container: nil, serviceRootPid: serviceRootOf[pid],
                    memoryBytes: proc.memoryBytes, cpuPercent: proc.cpuPercent, startTime: proc.startTime
                )
                if let root = serviceRootOf[pid], let svc = servicesByGroup[gid]?.first(where: { $0.rootPid == root }) {
                    binding.memoryBytes = svc.memoryBytes
                    binding.cpuPercent = svc.cpuPercent
                    binding.framework = svc.framework ?? binding.framework
                }
                if key.kind == .docker, let container = containerByPort[raw.port] {
                    binding.container = container.name
                    binding.framework = container.image
                    binding.memoryBytes = container.memoryBytes ?? 0
                    binding.cpuPercent = container.cpuPercent ?? 0
                    if let dir = container.workingDir, let project = resolver.resolve(path: dir) {
                        binding.groupID = "project:\(project.root)"
                        binding.groupName = project.name
                        binding.groupKind = .project
                        binding.projectRoot = project.root
                    }
                }
                bindings.append(binding)
            }
        }
        bindings.sort { ($0.port, $0.address) < ($1.port, $1.address) }

        var groups: [ProcessGroup] = []
        for (key, pids) in members {
            let procs = pids.compactMap { byPid[$0] }
            var origins: [String: Int] = [:]
            if key.kind == .headless {
                let set = Set(pids)
                for p in procs where !set.contains(p.ppid) {
                    let origin = ancestors(p.pid).lazy.compactMap { pid -> String? in
                        guard let k = assigned[pid], k.kind != .headless else { return nil }
                        return k.kind == .other ? nil : k.name
                    }.first ?? L("desconocido")
                    origins[origin, default: 0] += 1
                }
            }
            let frameworks = Array(Set((servicesByGroup[key.id] ?? []).compactMap(\.framework))).sorted()
            var groupContainers: [ContainerInfo] = []
            if key.kind == .project, let root = key.root { groupContainers = containersByRoot[root] ?? [] }
            if key.kind == .docker { groupContainers = containers }
            groups.append(ProcessGroup(
                id: key.id, kind: key.kind, name: key.name, detail: key.detail, projectRoot: key.root,
                pids: pids.sorted(),
                memoryBytes: procs.reduce(0) { $0 + $1.memoryBytes },
                cpuPercent: procs.reduce(0) { $0 + $1.cpuPercent },
                ports: bindings.filter { $0.groupID == key.id },
                services: servicesByGroup[key.id] ?? [],
                containers: groupContainers,
                frameworks: frameworks,
                origins: origins,
                offloadedBytes: procs.reduce(0) { $0 + $1.offloadedBytes },
                pageInRate: procs.reduce(0) { $0 + $1.pageInRate }
            ))
        }
        groups.sort { $0.memoryBytes > $1.memoryBytes }

        return Snapshot(time: now, processes: byPid, groups: groups, ports: bindings, containers: containers, pidToGroup: pidToGroup)
    }

    private func assignedIsHeadless(_ d: Direct?) -> Bool {
        if case .group(let key)? = d { return key.kind == .headless }
        return false
    }
}
