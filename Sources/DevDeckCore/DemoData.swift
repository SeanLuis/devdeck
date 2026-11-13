import Foundation

/// A made-up machine, used by `DevDeck --snapshot … --demo` to render screenshots that contain nobody's real
/// projects, accounts or processes. Nothing here is read from the Mac.
public struct DemoData: Sendable {
    public var snapshot: Snapshot
    public var system: SystemSample
    public var history: [SystemSample]
    public var usage: AgentUsageReport
    public var accounts: AccountsReport
    public var liveSessions: [LiveAgentSession]
    public var projects: [ProjectIdentity]
    public var projectCaches: [String: [CacheEntry]]
    public var globalCaches: [CacheEntry]
    public var alerts: [AlertEvent]
    public var timeline: [TimelinePoint] = []

    static let gb: UInt64 = 1 << 30
    static let mb: UInt64 = 1 << 20

    public static func make(now: Date = Date()) -> DemoData {
        let home = NSHomeDirectory()
        let code = home + "/Code"
        var processes: [Int32: ProcessRecord] = [:]
        var pidToGroup: [Int32: String] = [:]
        var nextPid: Int32 = 4100

        /// Adds `count` processes that share `total` bytes and returns their pids (the first one is the parent).
        func spawn(_ name: String, group: String, count: Int, total: UInt64, cpu: Double, cwd: String?, args: [String] = [], age: TimeInterval = 5400) -> [Int32] {
            var pids: [Int32] = []
            let root = nextPid
            for index in 0..<count {
                let pid = nextPid
                nextPid += 1
                let share = index == 0 ? total / 2 : total / 2 / UInt64(max(count - 1, 1))
                let memory = count == 1 ? total : share
                processes[pid] = ProcessRecord(pid: pid, ppid: index == 0 ? 1 : root, uid: 501, name: name, executablePath: "/usr/local/bin/\(name)",
                                               args: args.isEmpty ? [name] : args, cwd: cwd, startTime: now.addingTimeInterval(-age),
                                               memoryBytes: memory, cpuTimeNs: 0, cpuPercent: index == 0 ? cpu : 0, isMine: true,
                                               residentBytes: memory * 7 / 10)
                pidToGroup[pid] = group
                pids.append(pid)
            }
            return pids
        }

        var groups: [ProcessGroup] = []
        var ports: [PortBinding] = []

        func project(_ name: String, services: [(label: String, framework: String, port: UInt16, memory: UInt64, cpu: Double, command: String)],
                     containers: [ContainerInfo] = []) {
            let root = "\(code)/\(name)"
            let id = "project:\(root)"
            var infos: [ServiceInfo] = []
            var pids: [Int32] = []
            var bindings: [PortBinding] = []
            for service in services {
                let tree = spawn("node", group: id, count: 3, total: service.memory, cpu: service.cpu, cwd: root, args: service.command.split(separator: " ").map(String.init))
                pids += tree
                let start = now.addingTimeInterval(-5400)
                infos.append(ServiceInfo(rootPid: tree[0], label: service.label, command: service.command, cwd: root, appDir: root, dirs: [root],
                                         framework: service.framework, ports: [service.port], memoryBytes: service.memory, cpuPercent: service.cpu,
                                         pids: tree, startTime: start))
                bindings.append(PortBinding(port: service.port, address: "127.0.0.1", pid: tree[0], processName: "node", groupID: id, groupName: name,
                                            groupKind: .project, projectRoot: root, framework: service.framework, container: nil,
                                            serviceRootPid: tree[0], memoryBytes: service.memory, cpuPercent: service.cpu, startTime: start))
            }
            let memory = services.reduce(0) { $0 + $1.memory }
            groups.append(ProcessGroup(id: id, kind: .project, name: name, detail: Fmt.tilde(root), projectRoot: root, pids: pids, memoryBytes: memory,
                                       cpuPercent: services.reduce(0) { $0 + $1.cpu }, ports: bindings, services: infos, containers: containers,
                                       frameworks: Array(Set(services.map(\.framework))).sorted(), origins: [:], offloadedBytes: memory / 6))
            ports += bindings
        }

        func group(_ id: String, _ kind: GroupKind, _ name: String, detail: String, process: String, count: Int, memory: UInt64, cpu: Double,
                   cwd: String? = "/", origins: [String: Int] = [:], containers: [ContainerInfo] = [], offloaded: UInt64 = 0) {
            let pids = spawn(process, group: id, count: count, total: memory, cpu: cpu, cwd: cwd)
            groups.append(ProcessGroup(id: id, kind: kind, name: name, detail: detail, projectRoot: nil, pids: pids, memoryBytes: memory, cpuPercent: cpu,
                                       ports: [], services: [], containers: containers, frameworks: [], origins: origins, offloadedBytes: offloaded))
        }

        let containers = [
            ContainerInfo(id: "c1", name: "storefront-postgres-1", image: "postgres:17", state: "running", status: "Up 3 hours",
                          ports: [ContainerPort(hostPort: 5432, containerPort: 5432, proto: "tcp")], composeProject: "storefront",
                          workingDir: "\(code)/storefront", memoryBytes: 412 * mb, cpuPercent: 1.2),
            ContainerInfo(id: "c2", name: "storefront-redis-1", image: "redis:8", state: "running", status: "Up 3 hours",
                          ports: [ContainerPort(hostPort: 6379, containerPort: 6379, proto: "tcp")], composeProject: "storefront",
                          workingDir: "\(code)/storefront", memoryBytes: 64 * mb, cpuPercent: 0.3),
            ContainerInfo(id: "c3", name: "billing-api-mailhog-1", image: "mailhog/mailhog", state: "exited", status: "Exited (0) 2 days ago",
                          ports: [], composeProject: "billing-api", workingDir: "\(code)/billing-api", memoryBytes: nil, cpuPercent: nil),
        ]

        project("storefront", services: [
            ("next dev", "Next.js", 3000, 1_780 * mb, 6.4, "next dev --turbopack"),
            ("api", "tsx", 4000, 620 * mb, 1.1, "tsx watch src/server.ts"),
        ], containers: Array(containers.prefix(2)))
        project("billing-api", services: [("dev", "Vite", 5173, 940 * mb, 2.3, "vite --port 5173")])
        project("docs-site", services: [("astro dev", "Astro", 4321, 510 * mb, 0.4, "astro dev")])

        // Claude Code: two open sessions (their own process trees) plus helpers.
        let claude = "agent:Claude Code"
        let sessionA = spawn("claude", group: claude, count: 5, total: 1_050 * mb, cpu: 21, cwd: "\(code)/storefront", age: 2600)
        let sessionB = spawn("claude", group: claude, count: 4, total: 640 * mb, cpu: 0.4, cwd: "\(code)/billing-api", age: 9200)
        groups.append(ProcessGroup(id: claude, kind: .agent, name: "Claude Code", detail: "Agente de IA", projectRoot: nil, pids: sessionA + sessionB,
                                   memoryBytes: 1_690 * mb, cpuPercent: 21.4, ports: [], services: [], containers: [], frameworks: [], origins: [:],
                                   offloadedBytes: 300 * mb))
        group("agent:Codex", .agent, "Codex", detail: "Agente de IA", process: "codex", count: 3, memory: 720 * mb, cpu: 3.1, cwd: "\(code)/docs-site")
        group("agent:Cursor", .agent, "Cursor", detail: "Agente de IA", process: "Cursor", count: 9, memory: 1_340 * mb, cpu: 2.2)
        group(Classifier.dockerID, .docker, "Docker", detail: "Docker Desktop + VM de Linux", process: "com.docker.backend", count: 4, memory: 3_900 * mb, cpu: 4.8,
              containers: containers, offloaded: 1_400 * mb)
        group(Classifier.headlessID, .headless, "Chrome headless", detail: "Navegadores sin ventana (tests, scraping, capturas)", process: "Google Chrome",
              count: 14, memory: 1_480 * mb, cpu: 5.2, origins: ["Claude Code": 4, "storefront": 2])
        group("app:Google Chrome", .browser, "Google Chrome", detail: "/Applications/Google Chrome.app", process: "Google Chrome", count: 22, memory: 3_260 * mb, cpu: 7.9)
        group("app:Xcode", .app, "Xcode", detail: "/Applications/Xcode.app", process: "Xcode", count: 6, memory: 2_150 * mb, cpu: 1.4)
        group("app:Slack", .app, "Slack", detail: "/Applications/Slack.app", process: "Slack", count: 5, memory: 870 * mb, cpu: 0.8)
        group(Classifier.selfGroupID, .app, "DevDeck", detail: "Este panel", process: "DevDeck", count: 1, memory: 92 * mb, cpu: 0.9)
        group(Classifier.systemID, .system, "macOS", detail: "Procesos del sistema y de otros usuarios", process: "kernel_task", count: 40, memory: 3_050 * mb, cpu: 3.6)

        ports.append(PortBinding(port: 5432, address: "0.0.0.0", pid: processes.keys.max() ?? 1, processName: "com.docker.backend", groupID: "project:\(code)/storefront",
                                 groupName: "storefront", groupKind: .project, projectRoot: "\(code)/storefront", framework: nil,
                                 container: "storefront-postgres-1", serviceRootPid: nil, memoryBytes: 412 * mb, cpuPercent: 1.2, startTime: now.addingTimeInterval(-10_800)))
        groups.sort { $0.memoryBytes > $1.memoryBytes }
        let snapshot = Snapshot(time: now, processes: processes, groups: groups, ports: ports.sorted { $0.port < $1.port }, containers: containers, pidToGroup: pidToGroup)

        // System: a 32 GB Mac that is busy but fine, with a little history that moves.
        func sample(_ offset: Int) -> SystemSample {
            let wave = sin(Double(offset) / 9) * 0.9 + sin(Double(offset) / 31) * 1.6
            var s = SystemSample(time: now.addingTimeInterval(Double(offset) * 2), memTotal: 32 * gb, memUsed: UInt64(Double(23_900 * mb) + wave * Double(260 * mb)),
                                 memApp: 14 * gb, memWired: 3 * gb, memCompressed: 5_800 * mb, memCached: 4_200 * mb, pressure: 2,
                                 swapTotal: 3 * gb, swapUsed: UInt64(Double(1_950 * mb) + Double(offset + 300) * Double(mb) * 0.7),
                                 cpuPercent: max(4, 22 + wave * 7 + (offset % 37 == 0 ? 25 : 0)), diskFree: 211 * gb, diskTotal: 494 * gb)
            s.compressionRatio = 2.4
            return s
        }
        let history = (-300...0).map(sample)

        var data = DemoData(snapshot: snapshot, system: history[history.count - 1], history: history, usage: AgentUsageReport(), accounts: AccountsReport(),
                            liveSessions: [], projects: [], projectCaches: [:], globalCaches: [], alerts: [])

        // Agents: a week of tokens, the last hours, sessions and their subagents.
        var usage = AgentUsageReport()
        usage.installs = [
            AgentInstall(name: "Claude Code", binary: "claude", path: "/usr/local/bin/claude", version: "2.1.300 (Claude Code)", dataPath: nil),
            AgentInstall(name: "Codex", binary: "codex", path: "/usr/local/bin/codex", version: "codex-cli 0.150.0", dataPath: nil),
            AgentInstall(name: "Gemini CLI", binary: "gemini", path: "/usr/local/bin/gemini", version: nil, dataPath: nil),
            AgentInstall(name: "OpenCode", binary: "opencode", path: "/usr/local/bin/opencode", version: nil, dataPath: nil),
        ]
        func tokens(_ billable: UInt64, messages: Int) -> TokenCount {
            var t = TokenCount()
            t.input = billable / 20; t.output = billable / 5; t.cacheWrite = billable - billable / 20 - billable / 5
            t.cacheRead = billable * 18; t.messages = messages
            return t
        }
        let plan: [(agent: String, model: String, project: String, perDay: [UInt64])] = [
            ("Claude Code", "claude-opus-5-5", "\(code)/storefront", [38, 12, 44, 61, 29, 52, 47]),
            ("Claude Code", "claude-sonnet-5-5", "\(code)/billing-api", [9, 14, 6, 18, 11, 7, 13]),
            ("Codex", "gpt-6-astra", "\(code)/docs-site", [4, 0, 7, 3, 9, 2, 6]),
            ("Gemini CLI", "gemini-3-pro", "\(code)/billing-api", [0, 3, 0, 5, 2, 0, 4]),
            ("OpenCode", "kimi-k2.6", "\(code)/storefront", [2, 0, 1, 0, 3, 1, 2]),
        ]
        for entry in plan {
            for (index, millions) in entry.perDay.enumerated() where millions > 0 {
                let day = AgentUsageReport.dayString(now.addingTimeInterval(Double(index - 6) * 86_400))
                usage.buckets[UsageKey(agent: entry.agent, day: day, model: entry.model, project: entry.project)] = tokens(millions * 1_000_000, messages: Int(millions) * 40)
            }
        }
        let hour = Int(now.timeIntervalSince1970 / 3600)
        let hourly: [(String, [UInt64])] = [
            ("Claude Code", [0, 420, 910, 1_300, 760, 0, 0, 1_850, 2_400, 1_100, 2_900, 3_300]),
            ("Codex", [0, 0, 180, 0, 0, 0, 350, 0, 0, 240, 0, 410]),
            ("Gemini CLI", [0, 0, 0, 0, 260, 0, 0, 0, 0, 0, 190, 0]),
        ]
        for (agent, values) in hourly {
            for (index, thousands) in values.enumerated() where thousands > 0 {
                usage.hourly[agent, default: [:]][hour - 11 + index] = tokens(thousands * 1000, messages: Int(thousands) / 40)
            }
        }
        func session(_ agent: String, _ id: String, _ project: String, _ model: String, minutesAgo: Double, millions: Double, parent: String? = nil,
                     title: String? = nil, type: String? = nil) -> AgentSession {
            AgentSession(agent: agent, file: "\(home)/.demo/\(id).jsonl", project: project, lastActivity: now.addingTimeInterval(-minutesAgo * 60),
                         tokens: tokens(UInt64(millions * 1_000_000), messages: Int(millions * 40)), model: model, sizeBytes: 4 * mb,
                         sessionID: id, parentID: parent, title: title, agentType: type)
        }
        usage.sessions = [
            session("Claude Code", "demo-a", "\(code)/storefront", "claude-opus-5-5", minutesAgo: 0.5, millions: 6.2),
            session("Claude Code", "demo-a1", "\(code)/storefront", "claude-sonnet-5-5", minutesAgo: 0.4, millions: 0.9, parent: "demo-a", title: "Migrate checkout tests to Playwright", type: "general-purpose"),
            session("Claude Code", "demo-a2", "\(code)/storefront", "claude-haiku-5-5", minutesAgo: 1.1, millions: 0.3, parent: "demo-a", title: "Find every use of the old cart API", type: "Explore"),
            session("Claude Code", "demo-a3", "\(code)/storefront", "claude-sonnet-5-5", minutesAgo: 38, millions: 1.4, parent: "demo-a", title: "Review the pricing module", type: "code-reviewer"),
            session("Claude Code", "demo-b", "\(code)/billing-api", "claude-sonnet-5-5", minutesAgo: 22, millions: 2.1),
            session("Codex", "demo-c", "\(code)/docs-site", "gpt-6-astra", minutesAgo: 1.8, millions: 0.8),
            session("Claude Code", "demo-d", "\(code)/docs-site", "claude-opus-5-5", minutesAgo: 190, millions: 3.7),
            session("Claude Code", "demo-d1", "\(code)/docs-site", "claude-sonnet-5-5", minutesAgo: 200, millions: 0.6, parent: "demo-d", title: "Translate the guides to Portuguese", type: "general-purpose"),
            session("Gemini CLI", "demo-e", "\(code)/billing-api", "gemini-3-pro", minutesAgo: 420, millions: 0.5),
            session("OpenCode", "demo-f", "\(code)/storefront", "kimi-k2.6", minutesAgo: 900, millions: 0.3),
        ]
        usage.scannedAt = now
        data.usage = usage
        data.liveSessions = [
            LiveAgentSession(pid: sessionA[0], sessionID: "demo-a", cwd: "\(code)/storefront", status: "busy", name: "checkout-refactor", entrypoint: "cli",
                             startedAt: now.addingTimeInterval(-2600), updatedAt: now),
            LiveAgentSession(pid: sessionB[0], sessionID: "demo-b", cwd: "\(code)/billing-api", status: "idle", name: "invoice-export", entrypoint: "vscode",
                             startedAt: now.addingTimeInterval(-9200), updatedAt: now.addingTimeInterval(-1300)),
        ]

        // Accounts: three Claude Code logins managed by a switcher, and one Codex login.
        var accounts = AccountsReport()
        accounts.switcherPath = "/usr/local/bin/cswap"
        func account(_ number: Int, _ email: String, _ organization: String, active: Bool, plan: String?, _ windows: [(String, Double, Double, Bool?)]) -> AgentAccount {
            var a = AgentAccount(agent: "Claude Code", number: number, email: email, organization: organization, plan: plan, active: active)
            a.windows = windows.map { UsageWindow(name: $0.0, percent: $0.1, resetsAt: now.addingTimeInterval($0.2 * 3600), willLast: $0.3) }
            return a
        }
        accounts.accounts = [
            account(1, "alex@example.com", "Acme Labs", active: true, plan: "Max 5x", [("5 h", 64, 2.4, true), ("7 días", 38, 81, true), ("Fable", 22, 81, true)]),
            account(2, "alex@example.net", "Side Project", active: false, plan: nil, [("5 h", 0, 5, true), ("7 días", 81, 30, false), ("Fable", 46, 30, true)]),
            account(3, "team@example.org", "Open Source Org", active: false, plan: nil, [("5 h", 12, 3.1, true), ("7 días", 9, 120, true), ("Fable", 0, 120, true)]),
        ]
        var codex = AgentAccount(agent: "Codex", email: "alex@example.com", plan: "Plus", active: true)
        codex.windows = [UsageWindow(name: "5 h", percent: 18, resetsAt: now.addingTimeInterval(3.6 * 3600)), UsageWindow(name: "7 días", percent: 41, resetsAt: now.addingTimeInterval(96 * 3600))]
        accounts.accounts.append(codex)
        accounts.loadedAt = now
        data.accounts = accounts

        // Projects on disk and their caches.
        data.projects = ["storefront", "billing-api", "docs-site", "mobile-app", "design-system", "infra"].map { ProjectIdentity(root: "\(code)/\($0)", name: $0) }
        func cache(_ project: String, _ relative: String, _ kind: CacheKind, _ megabytes: UInt64, note: String, regenerate: String, safe: Bool) -> CacheEntry {
            CacheEntry(path: "\(code)/\(project)/\(relative)", label: (relative as NSString).lastPathComponent, kind: kind, sizeBytes: megabytes * mb,
                       projectRoot: "\(code)/\(project)", note: note, regenerate: regenerate, method: .deleteDirectory, safe: safe)
        }
        let auto = "Se regenera solo en el próximo dev/build"
        data.projectCaches = [
            "\(code)/storefront": [
                cache("storefront", "node_modules", .dependencies, 2_310, note: "Dependencias instaladas", regenerate: "pnpm install", safe: false),
                cache("storefront", "apps/web/.next", .buildCache, 1_640, note: "Build y caché de Next.js", regenerate: auto, safe: true),
                cache("storefront", ".turbo", .buildCache, 420, note: "Caché de Turborepo", regenerate: auto, safe: true),
            ],
            "\(code)/billing-api": [
                cache("billing-api", "node_modules", .dependencies, 980, note: "Dependencias instaladas", regenerate: "bun install", safe: false),
                cache("billing-api", ".venv", .virtualEnv, 1_320, note: "Entorno virtual de Python", regenerate: "uv sync / pip install -r requirements.txt", safe: false),
            ],
            "\(code)/mobile-app": [
                cache("mobile-app", "node_modules", .dependencies, 1_870, note: "Dependencias instaladas", regenerate: "npm ci", safe: false),
                cache("mobile-app", ".expo", .buildCache, 760, note: "Caché de Expo", regenerate: auto, safe: true),
            ],
            "\(code)/infra": [cache("infra", "target", .buildCache, 2_930, note: "Build de Rust (cargo)", regenerate: "cargo build", safe: true)],
        ]
        let sizes: [String: UInt64] = ["npm": 3_400, "pnpm store": 9_800, "Homebrew": 2_100, "Xcode DerivedData": 14_200, "Playwright": 1_900, "uv": 2_600,
                                       "Claude Code — transcripts": 5_300]
        data.globalCaches = CacheScanner.globalDefinitions.compactMap { definition in
            sizes[definition.label].map {
                CacheEntry(path: definition.path, label: definition.label, kind: definition.kind, sizeBytes: $0 * mb, projectRoot: nil, note: definition.note,
                           regenerate: definition.regenerate, method: definition.method, safe: definition.safe)
            }
        }.sorted { $0.sizeBytes > $1.sizeBytes }

        data.alerts = [
            AlertEvent(time: now.addingTimeInterval(-240), title: L("Enjambre de Chrome headless"), message: L("%@ navegadores headless abiertos", "14"), severity: .warning,
                       groupID: Classifier.headlessID),
            AlertEvent(time: now.addingTimeInterval(-1500), title: L("Servidor cerrado"),
                       message: L("%@ (%@) se cerró y no fue DevDeck. Puedes volver a arrancarlo desde Proyectos.", "astro dev", "docs-site"), severity: .info),
            AlertEvent(time: now.addingTimeInterval(-4100), title: L("Un proyecto usa > 6 GB"), message: "storefront: 6.3 GB", severity: .warning),
        ]
        // Six hours of history: a dev server that leaks, and one moment at the limit when a build ran.
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        data.timeline = (0..<360).map { index in
            let minute = nowMinute - 359 + index
            let build = index >= 170 && index < 182
            let leak = 700 + index * 5
            let wave = sin(Double(index) / 14) * 2.5
            let sources = [
                TimelinePoint.Source(id: Classifier.dockerID, name: "Docker", kind: "docker", memMB: 3900, cpu: 5),
                TimelinePoint.Source(id: "app:Google Chrome", name: "Google Chrome", kind: "browser", memMB: 3100 + Int(wave * 40), cpu: 8),
                TimelinePoint.Source(id: "project:\(code)/storefront", name: "storefront", kind: "project", memMB: leak, cpu: 6),
                TimelinePoint.Source(id: "app:Xcode", name: "Xcode", kind: "app", memMB: build ? 7600 : 2150, cpu: build ? 380 : 2),
                TimelinePoint.Source(id: "agent:Claude Code", name: "Claude Code", kind: "agent", memMB: 1500 + (index % 60) * 6, cpu: 20),
                TimelinePoint.Source(id: "project:\(code)/billing-api", name: "billing-api", kind: "project", memMB: 940, cpu: 2),
            ].sorted { $0.memMB > $1.memMB }
            return TimelinePoint(minute: minute, memPercent: (build ? 93 : 62 + Double(index) / 36 + wave).rounded(), memUsedMB: build ? 29_800 : 20_500 + index * 9,
                                 swapMB: 900 + index * 3 + (index >= 176 ? 900 : 0), cpu: build ? 88 : 22 + wave * 3, pressure: build ? 4 : 2, sources: sources)
        }
        return data
    }
}
