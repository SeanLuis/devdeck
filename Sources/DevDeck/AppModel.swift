import AppKit
import DevDeckCore
import Observation
import SwiftUI

struct MetricPoint: Hashable {
    let time: Date
    let memMB: Double
    let cpu: Double
}

struct ManagedRun: Identifiable {
    let id = UUID()
    let recipe: LaunchRecipe
    let logURL: URL
    let started: Date
    let process: Process

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: String
    var text: String
    var streaming = false
}

struct CacheReport: Codable {
    var date: Date
    var global: [CacheEntry]
    var projects: [String: [CacheEntry]]
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case overview, memory, ports, projects, agents, load, caches, toolkit, rules, copilot, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return L("Resumen")
        case .memory: return L("Memoria y swap")
        case .ports: return L("Puertos")
        case .projects: return L("Proyectos")
        case .agents: return L("Agentes de IA")
        case .load: return L("Carga por origen")
        case .caches: return L("Cachés y disco")
        case .toolkit: return L("Herramientas")
        case .rules: return L("Límites y alertas")
        case .copilot: return L("Copiloto IA")
        case .settings: return L("Ajustes")
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .memory: return "memorychip"
        case .ports: return "point.3.connected.trianglepath.dotted"
        case .projects: return "folder"
        case .agents: return "cpu"
        case .load: return "flame"
        case .caches: return "internaldrive"
        case .toolkit: return "wrench.and.screwdriver"
        case .rules: return "bell.badge"
        case .copilot: return "sparkles"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // Live state
    var snapshot: Snapshot = .empty
    var system: SystemSample = .empty
    var systemHistory: [SystemSample] = []
    var groupHistory: [String: [MetricPoint]] = [:]
    var hasSample = false
    var swapReport: SwapReport = .empty
    var agentUsage: AgentUsageReport = .empty
    var agentScanning = false
    var accounts: AccountsReport = .empty
    var liveSessions: [LiveAgentSession] = []
    var switchingAccount: String?
    var availableProviders: [AIProvider] = []
    var notificationStatus = "desconocido"
    var notificationsAllowed = false
    var aiKeyStatus: String?
    var aiVerifying = false

    // Projects & caches
    var discoveredProjects: [ProjectIdentity] = []
    var projectCaches: [String: [CacheEntry]] = [:]
    var globalCaches: [CacheEntry] = []
    var cacheScanProgress: String?
    var cacheScanDate: Date?

    // Rules, alerts, launches
    var rules: [Rule]
    var alerts: [AlertEvent]
    var recipes: [String: [LaunchRecipe]]
    var managedRuns: [ManagedRun] = []
    var busyPids: Set<Int32> = []

    var settings: AppSettings

    // AI
    var diagnosis: AIDiagnosis?
    var diagnosisDate: Date?
    var aiBusy = false
    var aiError: String?
    var chat: [ChatMessage] = []
    var autopilotLog: [String] = []
    var actionResults: [String: String] = [:]

    // UI
    var toast: String?
    var selectedSection: SidebarSection? = .overview
    var selectedProjectRoot: String?
    var paletteToken = UUID()
    var conversation: [AgentItem] = []
    var history: [StoredConversation] = []
    var recipeRuns: [String: RecipeRun] = [:]
    var storageBytes: UInt64 = 0
    @ObservationIgnored var conversationID: UUID?
    var islandAlert: IslandAlert?
    /// The island's boards are open (pinned by a click).
    var deckOpen = false
    var deckTab = "system"
    /// Number of conversation blocks when the user dismissed the copilot from the island; it comes back when there is something new.
    var copilotDismissedAt: Int?
    /// The launcher should open straight on the conversation (set by the island).
    var paletteWantsChat = false
    // Updates
    var availableUpdate: AppRelease?
    var showUpdate = false
    var updateChecking = false
    var updateInstalling = false
    var updateError: String?
    var lastUpdateCheck: Date?
    /// Changes whenever something asks the launcher (floating or embedded) to show the conversation.
    var chatToken = UUID()
    @ObservationIgnored var chatRequested = Date.distantPast

    /// Shows the current conversation in the copilot, wherever it is open.
    func showConversation() {
        chatRequested = Date()
        chatToken = UUID()
    }
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    @ObservationIgnored var islandTask: Task<Void, Never>?
    var agentRunning = false
    @ObservationIgnored var agentTask: Task<Void, Never>?

    @ObservationIgnored let sampler = Sampler()
    @ObservationIgnored let usageScanner = AgentUsageScanner()
    @ObservationIgnored let store: JSONStore
    @ObservationIgnored let ruleEngine = RuleEngine()
    @ObservationIgnored var loginEnv: [String: String] = ProcessInfo.processInfo.environment
    @ObservationIgnored var tasks: [Task<Void, Never>] = []
    @ObservationIgnored var lastAutoAI: Date = .distantPast
    @ObservationIgnored var dockerPath: String?
    @ObservationIgnored var capturedRoots: Set<Int32> = []
    /// Dev servers seen alive (root pid → what and where), to notice when one disappears.
    @ObservationIgnored var knownServices: [Int32: (label: String, project: String, since: Date)] = [:]
    /// Pids DevDeck itself is stopping: their exit is expected and needs no alert.
    @ObservationIgnored var expectedExits: Set<Int32> = []
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored let headless: Bool
    /// Runs on a made-up machine (for screenshots): nothing is sampled and nothing is written to the real data folder.
    @ObservationIgnored let demo: Bool

    init(headless: Bool = false, demo: Bool = false) {
        self.headless = headless
        self.demo = demo
        store = demo ? JSONStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-demo-\(UUID().uuidString)", isDirectory: true)) : JSONStore()
        let loaded = store.load("settings.json", as: AppSettings.self) ?? AppSettings()
        settings = loaded
        deckTab = loaded.deckTab
        L10n.language = loaded.language
        rules = store.load("rules.json", as: [Rule].self) ?? Rule.defaults
        alerts = store.load("alerts.json", as: [AlertEvent].self) ?? []
        recipes = store.load("recipes.json", as: [String: [LaunchRecipe]].self) ?? [:]
        // New default rules (e.g. swap) for people with an older rules.json.
        for rule in Rule.defaults where !rules.contains(where: { $0.metric == rule.metric && $0.targetGroupID == nil }) {
            rules.append(rule)
        }
        // The key used to come from a .env file path; now it lives in the app (paste once and forget).
        if AIKeyProvider.storedKey(store: store) == nil, let path = settings.ai.envFilePath,
           let key = AIKeyProvider.readEnvFile(path, variable: "OPENAI_API_KEY") {
            try? AIKeyProvider.store(key: key, store: store)
        }
        settings.ai.envFilePath = nil
        history = store.load("conversations.json", as: [StoredConversation].self) ?? []
        if let report = store.load("caches.json", as: CacheReport.self) {
            projectCaches = report.projects
            globalCaches = report.global
            cacheScanDate = report.date
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard tasks.isEmpty else { return }
        if demo { applyDemo(); return }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(max(1, self.settings.sampleInterval) * 1_000_000_000))
            }
        })
        tasks.append(Task { [weak self] in
            let env = await LoginEnvironment.load()
            guard let self else { return }
            self.loginEnv = env
            self.dockerPath = DockerProbe.dockerBinary(env: env)
            self.refreshProviders()
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshAgentUsage()
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                }
            }
            while !Task.isCancelled {
                await self.refreshDocker()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        })
        if !headless { refreshNotificationStatus() }
        if !headless {
            tasks.append(Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                while !Task.isCancelled {
                    if let self, self.settings.checkForUpdates { await self.checkForUpdates() }
                    try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
                }
            })
        }
        tasks.append(Task { [weak self] in
            await self?.discoverProjects()
            await self?.scanCaches(onlyIfStale: true)
        })
    }

    private func applyDemo() {
        let data = DemoData.make()
        snapshot = data.snapshot
        system = data.system
        systemHistory = data.history
        hasSample = true
        for group in data.snapshot.groups {
            groupHistory[group.id] = data.history.suffix(240).enumerated().map { index, sample in
                MetricPoint(time: sample.time, memMB: Fmt.mb(group.memoryBytes) * (0.93 + 0.07 * sin(Double(index) / 17 + Double(group.name.count))), cpu: group.cpuPercent)
            }
        }
        swapReport = SwapAnalyzer.analyze(history: systemHistory, snapshot: snapshot)
        agentUsage = data.usage
        accounts = data.accounts
        liveSessions = data.liveSessions
        discoveredProjects = data.projects
        projectCaches = data.projectCaches
        globalCaches = data.globalCaches
        cacheScanDate = Date().addingTimeInterval(-1800)
        alerts = data.alerts
        availableProviders = AIProvider.allCases
        settings.ai.provider = .claudeCode
        notificationStatus = L("permitidas")
        notificationsAllowed = true
    }

    func tick() async {
        let (snap, sys) = await sampler.sample()
        snapshot = snap
        system = sys
        hasSample = true

        let cutoff = sys.time.addingTimeInterval(-settings.historyMinutes * 60)
        systemHistory.append(sys)
        if let first = systemHistory.first, first.time < cutoff { systemHistory.removeAll { $0.time < cutoff } }
        for g in snap.groups where g.memoryBytes > 30_000_000 || g.kind == .project {
            groupHistory[g.id, default: []].append(MetricPoint(time: sys.time, memMB: Fmt.mb(g.memoryBytes), cpu: g.cpuPercent))
        }
        for key in Array(groupHistory.keys) {
            guard var points = groupHistory[key], let first = points.first, first.time < cutoff else { continue }
            points.removeAll { $0.time < cutoff }
            groupHistory[key] = points.isEmpty ? nil : points
        }

        swapReport = SwapAnalyzer.analyze(history: systemHistory, snapshot: snap)
        if !headless { IslandController.shared.update(model: self) }
        // The agents panel shows who is busy right now: keep it fresh while it is on screen.
        if selectedSection == .agents { Task { await self.refreshLiveSessions() } }
        captureNewServices(snap)
        for firing in ruleEngine.evaluate(rules: rules, snapshot: snap, system: sys, swap: swapReport) {
            handle(firing)
        }
    }

    /// Remember how every dev server was started, so it can be relaunched even after it dies.
    private func captureNewServices(_ snap: Snapshot) {
        let live = Set(snap.groups.flatMap { $0.services.map(\.rootPid) })
        capturedRoots.formIntersection(live)
        reportVanishedServices(live: live)
        for group in snap.groups where group.kind == .project {
            // Only real servers (something listening on a port): one-off commands such as a build, tsc or tail end by themselves.
            for service in group.services where knownServices[service.rootPid] == nil && !service.ports.isEmpty {
                knownServices[service.rootPid] = (service.label, group.name, Date())
            }
        }
        for group in snap.groups where group.kind == .project {
            for service in group.services where !capturedRoots.contains(service.rootPid) {
                capturedRoots.insert(service.rootPid)
                Task { await self.captureRecipe(service: service, group: group) }
            }
        }
    }

    /// A dev server that ends without DevDeck stopping it gets an alert: nothing should close a project silently.
    private func reportVanishedServices(live: Set<Int32>) {
        for (pid, info) in knownServices where !live.contains(pid) {
            knownServices[pid] = nil
            // Still running but no longer a "service" (e.g. it stopped listening): not a shutdown.
            if snapshot.processes[pid] != nil { continue }
            if expectedExits.remove(pid) != nil || Date().timeIntervalSince(info.since) < 60 { continue }
            let cause = Self.watchdogKill(within: 90)
            let message = cause.map { L("%@ (%@) se cerró. Lo cerró el vigilante de RAM: %@", info.label, info.project, $0) }
                ?? L("%@ (%@) se cerró y no fue DevDeck. Puedes volver a arrancarlo desde Proyectos.", info.label, info.project)
            pushAlert(AlertEvent(title: L("Servidor cerrado"), message: message, severity: cause == nil ? .info : .warning))
            notify(title: L("Servidor cerrado"), body: message, severity: cause == nil ? .info : .warning)
        }
        expectedExits.formIntersection(Set(snapshot.processes.keys))
    }

    /// What the separate RAM watchdog script (~/ram-watchdog.log) killed in the last seconds, if anything.
    static func watchdogKill(within seconds: TimeInterval) -> String? {
        let path = NSHomeDirectory() + "/ram-watchdog.log"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for line in tail.split(separator: "\n").reversed() where line.contains(" killed ") {
            guard line.count > 19, let date = format.date(from: String(line.prefix(19))) else { continue }
            return Date().timeIntervalSince(date) <= seconds ? String(line.dropFirst(20)) : nil
        }
        return nil
    }

    @discardableResult
    func captureRecipe(service: ServiceInfo, group: ProcessGroup) async -> LaunchRecipe? {
        guard let ctx = await sampler.launchContext(of: service.rootPid), !ctx.args.isEmpty else { return nil }
        let root = group.projectRoot ?? service.cwd ?? NSHomeDirectory()
        let recipe = LaunchRecipe(projectRoot: root, cwd: service.cwd ?? root, argv: ProcessControl.normalizedArgv(ctx.args),
                                  env: ctx.env, label: service.label, ports: service.ports)
        remember(recipe)
        return recipe
    }

    func refreshDocker() async {
        guard let docker = dockerPath, snapshot.group(Classifier.dockerID) != nil else {
            await sampler.setContainers([])
            return
        }
        let list = await DockerProbe.containers(docker: docker, env: loginEnv) ?? []
        await sampler.setContainers(list)
    }

    func discoverProjects() async {
        let roots = settings.projectRoots
        discoveredProjects = await Task.detached(priority: .utility) { ProjectDiscovery.scan(roots: roots) }.value
    }

    // MARK: - Derived

    var runningProjectRoots: Set<String> {
        Set(snapshot.groups.compactMap { $0.kind == .project ? $0.projectRoot : nil })
    }

    var projectsList: [ProjectIdentity] {
        var seen = Set<String>()
        var list: [ProjectIdentity] = []
        for g in snapshot.groups where g.kind == .project {
            if let root = g.projectRoot, seen.insert(root).inserted { list.append(ProjectIdentity(root: root, name: g.name)) }
        }
        for p in discoveredProjects where seen.insert(p.root).inserted { list.append(p) }
        return list
    }

    var allProjectCaches: [CacheEntry] { projectCaches.values.flatMap { $0 } }

    var devPorts: [PortBinding] {
        snapshot.ports.filter { $0.groupKind == .project || $0.container != nil || ($0.groupKind == .other && $0.framework != nil) }
    }

    func history(for id: String, minutes: Double) -> [MetricPoint] {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        return (groupHistory[id] ?? []).filter { $0.time >= cutoff }
    }

    func memoryTrends() -> [String: Double] {
        let cutoff = Date().addingTimeInterval(-600)
        var out: [String: Double] = [:]
        for (id, points) in groupHistory {
            guard let last = points.last, let past = points.first(where: { $0.time >= cutoff }) else { continue }
            out[id] = last.memMB - past.memMB
        }
        return out
    }

    /// Running services that may be using a cache. Deliberately conservative: a service counts if any of its
    /// processes works inside the cache's folder *or in a parent of it* (e.g. `pnpm --filter` / `turbo` from the repo
    /// root), across every group (nested repos), and dependencies count for every service of their project.
    func services(using entry: CacheEntry) -> [(ProcessGroup, ServiceInfo)] {
        let base = (entry.path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        let isDependency = entry.kind == .dependencies || entry.kind == .virtualEnv
        func overlaps(_ dir: String) -> Bool {
            guard dir != "/", dir != home else { return false }
            return dir == base || dir.hasPrefix(base + "/") || base.hasPrefix(dir + "/")
        }
        var result: [(ProcessGroup, ServiceInfo)] = []
        for group in snapshot.groups where !group.services.isEmpty {
            let sameProject = entry.projectRoot != nil && group.projectRoot == entry.projectRoot
            for service in group.services {
                let dirs = service.dirs + [service.appDir, service.cwd].compactMap { $0 }
                if (isDependency && sameProject) || dirs.contains(where: overlaps) { result.append((group, service)) }
            }
        }
        return result
    }

    func cacheEntry(path: String) -> CacheEntry? {
        let full = unredact(path)
        return allProjectCaches.first { $0.path == full } ?? globalCaches.first { $0.path == full }
    }

    // MARK: - Alerts

    private func handle(_ firing: RuleFiring) {
        var event = AlertEvent(title: firing.rule.name, message: firing.message, severity: firing.severity, groupID: firing.groupID)
        let group = firing.groupID.flatMap { snapshot.group($0) }
        switch firing.rule.action {
        case .notify:
            break
        case .killGroup:
            if let group, group.killable {
                event.actionTaken = L("Cerrado %@", group.name)
                Task { await self.kill(group: group) }
            }
        case .restartServices:
            if let group, !group.services.isEmpty {
                event.actionTaken = L("Reiniciando %@ servicio(s) de %@", "\(group.services.count)", group.name)
                Task { for s in group.services { await self.restart(service: s, in: group) } }
            }
        case .askAI:
            event.actionTaken = settings.ai.autopilot == .off ? nil : L("Diagnóstico IA en curso")
        }
        pushAlert(event)
        notify(title: firing.rule.name, body: firing.message + (event.actionTaken.map { " — \($0)" } ?? ""))

        let wantsAI = firing.rule.action == .askAI || (firing.severity == .critical && settings.ai.autoDiagnoseOnAlerts)
        if wantsAI, settings.ai.autopilot != .off, Date().timeIntervalSince(lastAutoAI) > settings.ai.autoDiagnoseEveryMinutes * 60 {
            lastAutoAI = Date()
            Task { await self.diagnose(focus: "Se disparó la alerta '\(firing.rule.name)': \(firing.message). ¿Qué la causa y qué hago?", automatic: true) }
        }
    }

    func pushAlert(_ event: AlertEvent) {
        alerts.insert(event, at: 0)
        if alerts.count > 300 { alerts.removeLast(alerts.count - 300) }
        store.save(alerts, "alerts.json")
    }

    func clearAlerts() {
        alerts.removeAll()
        store.save(alerts, "alerts.json")
    }

    func notify(title: String, body: String, severity: AlertSeverity = .warning, force: Bool = false) {
        guard !headless, settings.notificationsEnabled || force else { return }
        Notifier.shared.post(title: title, body: body, severity: severity)
    }

    /// In-app alert: shown on the island (or a corner banner if the island is off).
    func presentAlert(title: String, body: String, severity: AlertSeverity) {
        guard settings.islandMode != "off" else {
            BannerCenter.shared.show(title: title, body: body, severity: severity) { Notifier.shared.onOpen?(.rules) }
            return
        }
        islandAlert = IslandAlert(title: title, message: body, severity: severity)
        IslandController.shared.update(model: self)
        islandTask?.cancel()
        islandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled, let self {
                self.islandAlert = nil
                IslandController.shared.update(model: self)
            }
        }
    }

    func applyHotKey() {
        HotKey.set(keyCode: UInt32(settings.hotKeyCode), modifiers: UInt32(settings.hotKeyModifiers)) { PaletteController.shared.toggle() }
    }

    func refreshNotificationStatus() {
        Notifier.shared.currentStatus { [weak self] label, allowed in
            self?.notificationStatus = label
            self?.notificationsAllowed = allowed
        }
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: - Process actions

    /// Kills only PIDs that still are the same processes we saw (start time matches), so reused PIDs are safe.
    @discardableResult
    func terminateVerified(_ pids: [Int32], grace: TimeInterval = 4) async -> (graceful: Int, forced: Int) {
        expectedExits.formUnion(pids)
        var expected: [Int32: Date] = [:]
        for pid in pids { if let p = snapshot.processes[pid] { expected[pid] = p.startTime } }
        return await ProcessControl.terminate(pids, expectedStarts: expected, grace: grace)
    }

    func kill(group: ProcessGroup) async {
        guard group.killable else { return }
        show(L("Cerrando %@…", group.name))
        let apps = NSWorkspace.shared.runningApplications.filter { group.pids.contains($0.processIdentifier) }
        for app in apps { app.terminate() }
        if !apps.isEmpty { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        for service in group.services { await captureRecipe(service: service, group: group) }
        let remaining = group.pids.filter { Darwin.kill($0, 0) == 0 }
        let result = await terminateVerified(remaining)
        show(L("Cerrado %@ — %@ procesos", group.name, "\(group.pids.count)") + (result.forced > 0 ? L(" (%@ forzados)", "\(result.forced)") : ""))
        pushAlert(AlertEvent(title: L("Cerrado manualmente"), message: group.name, severity: .info, groupID: group.id))
    }

    func kill(pid: Int32) async {
        busyPids.insert(pid)
        defer { busyPids.remove(pid) }
        await terminateVerified([pid])
        show(L("Proceso %@ terminado", "\(pid)"))
    }

    func stop(service: ServiceInfo, in group: ProcessGroup) async {
        busyPids.insert(service.rootPid)
        defer { busyPids.remove(service.rootPid) }
        await captureRecipe(service: service, group: group)
        show(L("Deteniendo %@…", service.label))
        await terminateVerified(service.pids)
        show(L("Detenido %@. Puedes volver a arrancarlo desde el proyecto.", service.label))
    }

    func restart(service: ServiceInfo, in group: ProcessGroup, cleaning cachePaths: [String] = []) async {
        guard !busyPids.contains(service.rootPid) else { return }
        busyPids.insert(service.rootPid)
        defer { busyPids.remove(service.rootPid) }
        guard let recipe = await captureRecipe(service: service, group: group) else {
            show(L("No pude leer el comando de %@", service.label))
            return
        }
        show(L("Deteniendo %@…", service.label))
        await terminateVerified(service.pids)
        let free = await ProcessControl.waitUntilFree(ports: service.ports)
        if !cachePaths.isEmpty {
            show(L("Limpiando caché…"))
            let failures = await deletePaths(cachePaths)
            if !failures.isEmpty { pushAlert(AlertEvent(title: L("Limpieza incompleta"), message: failures.joined(separator: "; "), severity: .warning)) }
        }
        launch(recipe)
        if !free { show(L("Arrancado %@, pero el puerto %@ seguía ocupado", service.label, service.ports.map(String.init).joined(separator: ","))) }
    }

    /// Stops every service that uses the cache, deletes it, and starts them again with the same command and env.
    func cleanAndRestart(_ entry: CacheEntry) async {
        let affected = services(using: entry)
        var recipesToRun: [LaunchRecipe] = []
        for (group, service) in affected {
            guard let r = await captureRecipe(service: service, group: group) else {
                show(L("No pude leer el comando de %@; no toco nada para no dejarlo apagado.", service.label))
                return
            }
            recipesToRun.append(r)
        }
        show(L("Deteniendo %@ servicio(s)…", "\(affected.count)"))
        await terminateVerified(affected.flatMap { $0.1.pids })
        await ProcessControl.waitUntilFree(ports: affected.flatMap { $0.1.ports })
        let failures = await deletePaths([entry.path])
        for r in recipesToRun { launch(r) }
        if failures.isEmpty {
            show(L("Limpio %@ (%@) y reiniciado", L(entry.label), Fmt.bytes(entry.sizeBytes)))
        } else {
            show(L("Reiniciado, pero no se pudo borrar todo: %@", failures.joined(separator: "; ")))
        }
    }

    /// Deletes paths and returns error messages for the ones that failed (those stay listed).
    private func deletePaths(_ paths: [String]) async -> [String] {
        let failures: [String] = await Task.detached(priority: .userInitiated) {
            var errors: [String] = []
            for p in paths {
                do { try FileManager.default.removeItem(atPath: p) }
                catch { errors.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)") }
            }
            return errors
        }.value
        for p in paths where !FileManager.default.fileExists(atPath: p) {
            for key in Array(projectCaches.keys) { projectCaches[key]?.removeAll { $0.path == p } }
        }
        saveCacheReport()
        return failures
    }

    func launch(_ recipe: LaunchRecipe) {
        do {
            let (process, log) = try ProcessControl.launch(recipe, logDirectory: store.logsDirectory, fallbackEnv: loginEnv)
            managedRuns.insert(ManagedRun(recipe: recipe, logURL: log, started: Date(), process: process), at: 0)
            remember(recipe)
            show(L("Arrancado: %@", recipe.label))
        } catch {
            show(L("No se pudo arrancar %@: %@", recipe.label, error.localizedDescription))
        }
    }

    func remember(_ recipe: LaunchRecipe) {
        var list = recipes[recipe.projectRoot] ?? []
        list.removeAll { $0.id == recipe.id }
        list.insert(recipe, at: 0)
        recipes[recipe.projectRoot] = Array(list.prefix(6))
        store.save(recipes, "recipes.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.directory.appendingPathComponent("recipes.json").path)
    }

    func forget(_ recipe: LaunchRecipe) {
        recipes[recipe.projectRoot]?.removeAll { $0.id == recipe.id }
        store.save(recipes, "recipes.json")
    }

    func managedRun(for pid: Int32) -> ManagedRun? { managedRuns.first { $0.pid == pid && $0.isRunning } }

    // MARK: - Caches

    func scanCaches(onlyIfStale: Bool = false) async {
        guard cacheScanProgress == nil else { return }
        if onlyIfStale, let date = cacheScanDate, Date().timeIntervalSince(date) < 6 * 3600 { return }
        if discoveredProjects.isEmpty { await discoverProjects() }
        let projects = projectsList
        cacheScanProgress = L("Cachés globales…")
        globalCaches = await CacheScanner.scanGlobal()
        var results: [String: [CacheEntry]] = [:]
        for (index, project) in projects.enumerated() {
            cacheScanProgress = L("Proyecto %@ de %@: %@", "\(index + 1)", "\(projects.count)", project.name)
            let entries = await CacheScanner.scanProject(project)
            if !entries.isEmpty {
                results[project.root] = entries
                projectCaches[project.root] = entries
            }
        }
        projectCaches = results
        cacheScanDate = Date()
        cacheScanProgress = nil
        saveCacheReport()
    }

    func saveCacheReport() {
        store.save(CacheReport(date: cacheScanDate ?? Date(), global: globalCaches, projects: projectCaches), "caches.json")
    }

    func clean(_ entry: CacheEntry) async {
        show(L("Limpiando %@…", L(entry.label)))
        let message = await CacheScanner.clean(entry, env: loginEnv)
        if let root = entry.projectRoot {
            if FileManager.default.fileExists(atPath: entry.path) {
                if let index = projectCaches[root]?.firstIndex(where: { $0.path == entry.path }) {
                    projectCaches[root]?[index].sizeBytes = await CacheScanner.size(of: entry.path)
                }
            } else {
                projectCaches[root]?.removeAll { $0.path == entry.path }
            }
        } else if let index = globalCaches.firstIndex(where: { $0.path == entry.path }) {
            globalCaches[index].sizeBytes = await CacheScanner.size(of: entry.path)
        }
        saveCacheReport()
        show(message)
        pushAlert(AlertEvent(title: L("Limpieza"), message: message, severity: .info))
    }

    // MARK: - Rules

    func saveRules() { store.save(rules, "rules.json") }
    func saveSettings() {
        // One language for the whole app: the interface and the copilot's answers.
        if L10n.language != settings.language { L10n.language = settings.language }
        settings.ai.language = settings.language.aiName
        // Headless runs (snapshots, smoke tests) may change settings in memory; they must not touch the user's file.
        if !headless || demo { store.save(settings, "settings.json") }
    }

    func limitRule(for groupID: String) -> Rule? {
        rules.first { $0.metric == .groupMemoryMB && $0.targetGroupID == groupID }
    }

    func setLimit(groupID: String, name: String, mb: Double, action: RuleAction) {
        if let index = rules.firstIndex(where: { $0.metric == .groupMemoryMB && $0.targetGroupID == groupID }) {
            rules[index].threshold = mb
            rules[index].action = action
            rules[index].enabled = true
        } else {
            rules.append(Rule(name: L("Límite de RAM: %@", name), metric: .groupMemoryMB, threshold: mb, targetGroupID: groupID,
                              sustainSeconds: 20, action: action, cooldownSeconds: 600))
        }
        saveRules()
    }

    func removeLimit(groupID: String) {
        rules.removeAll { $0.metric == .groupMemoryMB && $0.targetGroupID == groupID }
        saveRules()
    }

    // MARK: - AI

    var aiKeyAvailable: Bool { AIKeyProvider.key(config: settings.ai, store: store) != nil }

    /// True when the selected engine can answer (CLI installed, or key present for the API).
    var aiReady: Bool { availableProviders.contains(settings.ai.provider) }

    var aiEngineLabel: String {
        switch settings.ai.provider {
        case .claudeCode: return "Claude Code" + (settings.ai.claudeModel == "default" ? "" : " · \(settings.ai.claudeModel)")
        case .codex: return "Codex" + (settings.ai.codexModel == "default" ? "" : " · \(settings.ai.codexModel)")
        case .openAI: return settings.ai.model
        }
    }

    func refreshProviders() {
        availableProviders = AIEngine.available(env: loginEnv, store: store, config: settings.ai)
        // First run: prefer an agent the user is already logged into, so no key is needed.
        if !settings.ai.providerChosen, let first = availableProviders.first {
            settings.ai.provider = first
            settings.ai.providerChosen = true
            saveSettings()
        }
    }

    func refreshAgentUsage() async {
        guard !agentScanning else { return }
        agentScanning = true
        if agentUsage.installs.isEmpty { agentUsage.installs = await usageScanner.installs(env: loginEnv) }
        agentUsage = await usageScanner.scan(days: 7, env: loginEnv)
        agentScanning = false
        await refreshAccounts()
        await refreshLiveSessions()
    }

    func backend() throws -> AIBackend {
        try AIEngine.backend(config: settings.ai, store: store, env: loginEnv)
    }

    func aiPayload() -> String {
        AISnapshotBuilder.build(snapshot: snapshot, system: system, caches: allProjectCaches + globalCaches,
                                alerts: alerts, memoryTrendMB: memoryTrends(), swap: swapReport,
                                includeCommands: settings.ai.shareCommandLines)
    }

    var storedKeyMasked: String? { AIKeyProvider.storedKey(store: store).map(AIKeyProvider.masked) }

    /// Saves the pasted key, checks it against the API and loads the models it can use.
    func saveAndVerifyKey(_ raw: String?) async {
        if let raw {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            do { try AIKeyProvider.store(key: key, store: store) } catch {
                aiKeyStatus = L("No se pudo guardar: %@", error.localizedDescription)
                return
            }
        }
        guard let key = AIKeyProvider.key(config: settings.ai, store: store) else {
            aiKeyStatus = AIError.missingKey.localizedDescription
            return
        }
        aiVerifying = true
        defer { aiVerifying = false }
        do {
            let models = try await OpenAIClient(config: settings.ai, apiKey: key).listModels()
            settings.ai.availableModels = models
            if !models.isEmpty, !models.contains(settings.ai.model) {
                settings.ai.model = models.first { $0.hasPrefix("gpt-6") } ?? models[0]
            }
            saveSettings()
            aiKeyStatus = L("Conectado · %@ modelos disponibles", "\(models.count)")
            refreshProviders()
        } catch {
            aiKeyStatus = error.localizedDescription
        }
    }

    func removeKey() {
        AIKeyProvider.removeKey(store: store)
        aiKeyStatus = L("Key eliminada")
        refreshProviders()
    }

    /// Raycast-style answer that streams in token by token.
    func askStreaming(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiBusy else { return }
        chat.append(ChatMessage(role: "user", text: trimmed))
        aiBusy = true
        defer { aiBusy = false }
        let history = chat.map { AIChatTurn(role: $0.role, text: $0.text) }
        chat.append(ChatMessage(role: "assistant", text: "", streaming: true))
        let index = chat.count - 1
        do {
            for try await delta in try backend().streamChat(history: history, snapshotJSON: aiPayload()) {
                chat[index].text += delta
            }
            if chat[index].text.isEmpty { chat[index].text = L("(sin respuesta)") }
        } catch {
            chat[index].text += (chat[index].text.isEmpty ? "" : "\n\n") + "\(error.localizedDescription)"
        }
        chat[index].streaming = false
    }

    func diagnose(focus: String? = nil, automatic: Bool = false) async {
        guard !aiBusy else { return }
        aiBusy = true
        aiError = nil
        defer { aiBusy = false }
        do {
            let result = try await backend().diagnose(snapshotJSON: aiPayload(), focus: focus)
            diagnosis = result
            diagnosisDate = Date()
            actionResults = [:]
            if automatic {
                log(L("Diagnóstico automático: %@", result.summary))
                if settings.ai.autopilot == .autoSafe {
                    for action in result.actions {
                        // Re-validated against the latest snapshot immediately before acting; never escalates.
                        guard isAutoSafe(action) else { continue }
                        let outcome = await apply(action, automatic: true)
                        log("  ↳ \(action.title): \(outcome)")
                    }
                }
                notify(title: L("Copiloto IA"), body: result.summary)
            }
        } catch {
            aiError = error.localizedDescription
            if automatic { log(L("Error de IA: %@", error.localizedDescription)) }
        }
    }

    func ask(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !aiBusy else { return }
        await askStreaming(trimmed)
    }

    private func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        autopilotLog.insert("\(stamp)  \(line)", at: 0)
        if autopilotLog.count > 200 { autopilotLog.removeLast() }
    }

    func unredact(_ value: String) -> String {
        let home = NSHomeDirectory()
        if value.hasPrefix("~/") { return home + value.dropFirst() }
        return value.replacingOccurrences(of: ":~/", with: ":\(home)/")
    }

    func isAutoSafe(_ action: AIAction) -> Bool {
        guard action.risk == "low" else { return false }
        switch action.type {
        case "kill_group":
            return unredact(action.target) == Classifier.headlessID
        case "clean_cache":
            guard let entry = cacheEntry(path: action.target), entry.safe, entry.kind == .buildCache else { return false }
            return services(using: entry).isEmpty
        default:
            return false
        }
    }

    /// Validates an AI-proposed action against the live snapshot and runs it.
    func apply(_ action: AIAction, automatic: Bool = false) async -> String {
        let target = unredact(action.target)
        let outcome: String
        switch action.type {
        case "kill_group":
            // "other:" groups merge same-named processes, so they are never touched without an explicit human approval.
            guard let group = snapshot.group(target), group.killable, !(automatic && group.kind == .other) else {
                outcome = L("Grupo no válido o protegido"); break
            }
            if automatic && group.kind != .headless { outcome = L("Solo se cierran navegadores headless en automático"); break }
            await kill(group: group)
            outcome = L("Cerrado %@", group.name)
        case "kill_process":
            guard let pid = Int32(target), let proc = snapshot.processes[pid], proc.isMine, pid != getpid(),
                  let owner = snapshot.group(forPid: pid), owner.killable else { outcome = L("PID no válido o protegido"); break }
            if automatic { outcome = L("En automático no se matan procesos sueltos"); break }
            await kill(pid: pid)
            outcome = L("Proceso %@ terminado", "\(pid)")
        case "restart_service":
            guard let pid = Int32(target), let found = snapshot.service(rootPid: pid) ?? snapshot.service(containing: pid) else {
                outcome = L("Servicio no encontrado"); break
            }
            if automatic { outcome = L("En automático no se reinician servicios"); break }
            await restart(service: found.1, in: found.0)
            outcome = L("Reiniciado %@", found.1.label)
        case "clean_cache":
            guard let entry = cacheEntry(path: target) else { outcome = L("Caché no reconocida"); break }
            let inUse = !services(using: entry).isEmpty
            if automatic && (inUse || !entry.safe) { outcome = L("En uso o no regenerable: no se toca en automático"); break }
            if inUse { await cleanAndRestart(entry) } else { await clean(entry) }
            outcome = L("Limpio %@", L(entry.label))
        case "set_memory_limit":
            guard let group = snapshot.group(target), let mb = action.value, mb > 0 else { outcome = L("Límite no válido"); break }
            setLimit(groupID: group.id, name: group.name, mb: mb, action: .notify)
            outcome = L("Alerta creada: avisaré si %@ pasa de %d MB. No reduce su memoria.", group.name, Int(mb))
        case "set_docker_memory":
            if automatic { outcome = L("En automático no se cambia la configuración de Docker"); break }
            guard let mb = action.value, mb >= 2048, Double(system.memTotal) / 1_048_576 >= mb else { outcome = L("Tamaño no válido (mínimo 2048 MB)"); break }
            outcome = await setDockerMemory(Int(mb))
        case "run_tool":
            if automatic { outcome = L("En automático no se ejecutan herramientas"); break }
            guard let recipe = Toolkit.recipe(target), LoginEnvironment.which(recipe.tool, env: loginEnv) != nil else {
                outcome = L("Receta no disponible en este Mac"); break
            }
            await run(recipe)
            let result = recipeRuns[recipe.id]
            outcome = (result?.ok == true ? L("Hecho: %@", recipe.title) : L("Falló: %@", recipe.title))
                + (result.map { $0.output.isEmpty ? "" : "\n" + String($0.output.suffix(900)) } ?? "")
        default:
            outcome = L("Acción desconocida")
        }
        actionResults[action.id] = outcome
        return outcome
    }

    /// Really lowers Docker's memory: changes the size of Docker Desktop's VM and restarts it so it applies.
    func setDockerMemory(_ mb: Int) async -> String {
        guard let before = DockerDesktop.memoryMiB() else { return L("No encuentro la configuración de Docker Desktop") }
        guard before != mb else { return L("Docker ya tiene %d MB asignados", mb) }
        do { try DockerDesktop.setMemoryMiB(mb) } catch { return L("No pude guardar la configuración de Docker: %@", error.localizedDescription) }
        show(L("Reiniciando Docker con %d MB…", mb))
        var restarted = false
        if let docker = dockerPath {
            restarted = await Shell.run(docker, ["desktop", "restart"], env: loginEnv, timeout: 180).ok
        }
        if !restarted {
            _ = await Shell.run("/usr/bin/osascript", ["-e", "quit app \"Docker Desktop\""], timeout: 30)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            restarted = await Shell.run("/usr/bin/open", ["-a", "Docker"], timeout: 15).ok
        }
        pushAlert(AlertEvent(title: L("Memoria de Docker"), message: L("VM de %d MB (antes %d MB)", mb, before), severity: .info, groupID: Classifier.dockerID))
        return restarted ? L("Docker reiniciado con %d MB de RAM (antes %d MB).", mb, before)
                         : L("Guardado: %d MB (antes %d MB). Reinicia Docker Desktop para aplicarlo.", mb, before)
    }

    // MARK: - Shell helpers

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTerminal(at path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func openInBrowser(port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}
