import AppKit
import DevDeckCore
import Carbon.HIToolbox
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // Called by Claude Code's hooks: note what it says and leave at once, printing nothing.
        if args.count > 2, args[1] == "hook", args[2] == "--devdeck" {
            ClaudeHooks.record(FileHandle.standardInput.readDataToEndOfFile(), directory: JSONStore().directory)
            return
        }
        if let index = args.firstIndex(of: "--record"), args.count > index + 1 {
            MainActor.assumeIsolated { SnapshotRunner.record(outDir: args[index + 1]) }
            return
        }
        if let index = args.firstIndex(of: "--snapshot") {
            let dir = args.count > index + 1 ? args[index + 1] : NSTemporaryDirectory() + "devdeck-shots"
            MainActor.assumeIsolated { SnapshotRunner.run(outDir: dir) }
            return
        }
        if let index = args.firstIndex(of: "--render-icon"), args.count > index + 1 {
            MainActor.assumeIsolated { IconRenderer.render(to: args[index + 1]) }
            return
        }
        if args.contains("--notify-test") {
            MainActor.assumeIsolated { NotifyProbe.run() }
            return
        }
        if let index = args.firstIndex(of: "--agent-smoke") {
            let question = args.count > index + 1 ? args[index + 1] : "¿Qué consume más RAM?"
            MainActor.assumeIsolated { CLI.agentSmoke(question) }
            return
        }
        if args.contains("--update-check") {
            CLI.updateCheck(installInto: args.firstIndex(of: "--install-into").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil })
            return
        }
        if args.contains("--usage-dump") {
            CLI.usageDump()
            return
        }
        if args.contains("--engine-smoke") {
            CLI.engineSmoke()
            return
        }
        if args.contains("--ai-smoke") {
            CLI.aiSmoke()
            return
        }
        // `devdeck status|top|ports|agents [--json]` and `devdeck mcp`: the same readings without the window.
        if args.count > 1, args[1] == "mcp" || Reports.topics.contains(args[1]) || args[1] == "help" || args[1] == "--help" {
            CLI.command(args[1], json: args.contains("--json"))
            return
        }
        if args.contains("--accounts-dump") {
            CLI.accountsDump(readUsage: args.contains("--usage"))
            return
        }
        if args.contains("--dump") {
            CLI.dump()
            return
        }
        DevDeckApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Notifier.shared.setup()
            // The launcher shortcut (default ⌥⌘D) opens the copilot palette from anywhere.
            if let model = PaletteController.shared.model {
                model.applyHotKey()
                IslandController.shared.update(model: model)
            }
        }
    }

    /// Coming back from System Settings: pick up a notification permission the user just granted.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { PaletteController.shared.model?.refreshNotificationStatus() }
    }

    /// Nothing stays frozen when DevDeck quits.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { _ = PaletteController.shared.model?.resumePaused() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q or "Quit" from the Dock closes the window and leaves DevDeck in the menu bar, when the user wants that.
    /// "Quit DevDeck" in the menu bar panel, an update, and logging out or shutting down still end it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = PaletteController.shared.model, model.settings.keepInMenuBar, !AppPresence.quitting,
                  AppPresence.personIsClosing else { return .terminateNow }
            AppPresence.hideToMenuBar()
            return .terminateCancel
        }
    }
}

/// Whether DevDeck shows as a regular app (window and Dock icon) or lives only in the menu bar.
@MainActor
enum AppPresence {
    /// Set by the actions that really mean to end DevDeck.
    static var quitting = false

    static func quit() {
        quitting = true
        NSApp.terminate(nil)
    }

    /// The person closing DevDeck: ⌘Q or the app menu (no Apple event), or "Quit" on its Dock icon. A quit from the
    /// system (logout, restart, shutdown), from a script or from another app is obeyed at once.
    static var personIsClosing: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return true }
        guard event.eventID == kAEQuitApplication else { return false }
        let reason = event.attributeDescriptor(forKeyword: kAEQuitReason) ?? event.paramDescriptor(forKeyword: kAEQuitReason)
        if (reason?.enumCodeValue ?? 0) != 0 { return false }
        guard let sender = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value else { return false }
        return NSRunningApplication(processIdentifier: sender)?.bundleIdentifier == "com.apple.dock"
    }

    static var mainWindows: [NSWindow] { NSApp.windows.filter { $0.identifier?.rawValue == "main" || $0.title == "DevDeck" } }

    static func hideToMenuBar() {
        for window in mainWindows { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Before the window opens: the Dock icon comes back with it.
    static func showApp() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DevDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        PaletteController.shared.model = model
        Notifier.shared.onOpen = { section in
            model.selectedSection = section
            AppPresence.showApp()
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "DevDeck" }?.makeKeyAndOrderFront(nil)
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("DevDeck", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 720)
                .onAppear { AppPresence.showApp() }
                // Closing the window leaves DevDeck in the menu bar without a Dock icon.
                .onDisappear { if model.settings.keepInMenuBar { NSApp.setActivationPolicy(.accessory) } }
                .appAppearance(model.settings.appearance)
                .appLanguage(model.settings.language)
        }
        .defaultSize(width: 1400, height: 900)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .appAppearance(model.settings.appearance)
                .appLanguage(model.settings.language)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// System notifications when macOS allows them, plus DevDeck's own banner (always works, even if macOS blocks the app).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var onOpen: ((SidebarSection) -> Void)?
    private(set) var systemAllowed = false

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.systemAllowed = granted }
        }
    }

    func currentStatus(_ completion: @escaping @MainActor (String, Bool) -> Void) {
        guard isBundled else { completion(L("no disponible (sin bundle)"), false); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let label: String
            let allowed: Bool
            switch settings.authorizationStatus {
            case .authorized: label = L("permitidas"); allowed = true
            case .provisional: label = L("permitidas (silenciosas)"); allowed = true
            case .denied: label = L("bloqueadas por macOS"); allowed = false
            case .notDetermined: label = L("sin decidir"); allowed = false
            default: label = L("desconocido"); allowed = false
            }
            Task { @MainActor in
                self.systemAllowed = allowed
                completion(label, allowed)
            }
        }
    }

    func post(title: String, body: String, severity: AlertSeverity = .warning) {
        if isBundled && systemAllowed {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        } else if let model = PaletteController.shared.model {
            model.presentAlert(title: title, body: body, severity: severity)
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "dev.devdeck.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?(.rules) }
    }
}

/// `DevDeck --dump`: prints what the classifier sees (useful for debugging attribution).
enum CLI {
    /// Runs one full agent conversation headless and prints every block (thought, plan, tools, approvals, answer).
    @MainActor
    static func agentSmoke(_ question: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel(headless: true)
        model.start()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            let t0 = Date()
            await model.runAgent(question)
            for item in model.conversation {
                switch item.kind {
                case .user: print("USER:", item.text)
                case .thought: print("THOUGHT (\(String(format: "%.1f", item.seconds))s):", item.text.prefix(140))
                case .plan: print("PLAN:", item.plan.map { "[\($0.status)] \($0.title)" }.joined(separator: " | "))
                case .tool: print("TOOL \(item.toolName)(\(item.toolArgument)) → \(item.toolState.rawValue):", item.toolResult.prefix(110).replacingOccurrences(of: "\n", with: " ⏎ "))
                case .approval: print("APPROVAL:", item.action.map { "\($0.type)(\($0.target)) risk=\($0.risk) — \($0.reason.prefix(90))" } ?? "")
                case .answer: print("ANSWER:", item.text.prefix(420))
                case .error: print("ERROR:", item.text)
                }
            }
            print("total \(String(format: "%.1f", Date().timeIntervalSince(t0)))s · motor:", model.aiEngineLabel)
            exit(0)
        }
        app.run()
    }

    /// Asks GitHub for the latest release. With `--install-into <copy of DevDeck.app>` it also runs the real
    /// download → verify → replace on that copy, to test the updater without touching the installed app.
    static func updateCheck(installInto path: String?) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                guard let latest = try await Updates.fetchLatest() else { print("no release found"); done.signal(); return }
                print("latest:", latest.version, "· download:", latest.downloadURL ?? "-", "· notes:", latest.notes.count, "chars")
                if let path {
                    let before = await Updates.teamIdentifier(ofApp: path)
                    try await Updates.install(latest, replacing: path)
                    let after = await Updates.teamIdentifier(ofApp: path)
                    let version = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
                    print("installed into \(path): version \(version ?? "?") · team before \(before ?? "ad-hoc") → after \(after ?? "?")")
                }
            } catch { print("ERROR:", error.localizedDescription) }
            done.signal()
        }
        done.wait()
    }

    static func usageDump() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let env = await LoginEnvironment.load()
            let scanner = AgentUsageScanner()
            var t0 = Date()
            let report = await scanner.scan(days: 7, env: env)
            print("first scan \(String(format: "%.1f", Date().timeIntervalSince(t0)))s · installs:", report.installs.map { "\($0.name) \($0.version ?? "")" })
            for agent in report.agents {
                let t = report.total(agent: agent)
                print(" \(agent): \(t.messages) respuestas · in \(t.input) out \(t.output) cacheW \(t.cacheWrite) cacheR \(t.cacheRead)")
            }
            print(" sessions:", report.sessions.count, "subagents:", report.sessions.filter(\.isSubagent).count, "plan:", report.codexPlan?.planType ?? "-")
            for agent in report.agents {
                let window = report.recent(agent: agent, hours: 5)
                print(" last 5h \(agent): \(window.billable) tokens · \(window.messages) respuestas")
            }
            let accounts = await AgentAccounts.load(env: env, codexPlan: report.codexPlan)
            print(" accounts: \(accounts.accounts.count) · switcher:", accounts.switcherPath == nil ? "no" : "cswap")
            for account in accounts.accounts {
                let windows = account.windows.map { "\($0.name) \(Int($0.percent))%" }.joined(separator: ", ")
                print("  [\(account.agent)] #\(account.number.map(String.init) ?? "-") \(account.active ? "activa" : "      ") plan \(account.plan ?? "-") · \(windows)")
            }
            t0 = Date()
            _ = await scanner.scan(days: 7, env: env)
            print("second scan \(String(format: "%.2f", Date().timeIntervalSince(t0)))s (incremental)")
            done.signal()
        }
        done.wait()
    }

    /// Runs a real diagnosis + chat through each local agent engine (Claude Code, Codex).
    static func engineSmoke() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let env = await LoginEnvironment.load()
            let store = JSONStore()
            let sampler = Sampler()
            _ = await sampler.sample()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let (snap, sys) = await sampler.sample()
            let json = AISnapshotBuilder.build(snapshot: snap, system: sys, caches: [], alerts: [], memoryTrendMB: [:])
            var config = AIConfig()
            print("available:", AIEngine.available(env: env, store: store, config: config).map(\.title))
            for provider in [AIProvider.claudeCode, .codex] {
                config.provider = provider
                do {
                    let backend = try AIEngine.backend(config: config, store: store, env: env)
                    var t0 = Date()
                    let d = try await backend.diagnose(snapshotJSON: json, focus: "Resume en una frase qué consume más RAM.")
                    print("[\(provider.title)] diagnose \(String(format: "%.1f", Date().timeIntervalSince(t0)))s · findings \(d.findings.count) · actions \(d.actions.count) ·", d.summary.prefix(110))
                    t0 = Date()
                    var chunks = 0, text = ""
                    for try await delta in backend.streamChat(history: [AIChatTurn(role: "user", text: "¿Cuánto swap hay en uso? Una línea.")], snapshotJSON: json) {
                        chunks += 1; text += delta
                    }
                    print("[\(provider.title)] chat \(String(format: "%.1f", Date().timeIntervalSince(t0)))s · \(chunks) chunks ·", text.prefix(110))
                } catch { print("[\(provider.title)] ERROR:", error.localizedDescription) }
            }
            done.signal()
        }
        done.wait()
    }

    /// Verifies the key, model list, reasoning parameter and streaming against the real API (no secrets printed).
    static func aiSmoke() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let store = JSONStore()
            var config = (store.load("settings.json", as: AppSettings.self) ?? AppSettings()).ai
            guard let key = AIKeyProvider.key(config: config, store: store) else { print("NO KEY"); done.signal(); return }
            print("key:", AIKeyProvider.masked(key), "model:", config.model)
            do {
                let models = try await OpenAIClient(config: config, apiKey: key).listModels()
                print("models:", models.count, models.prefix(8).joined(separator: ", "))
            } catch { print("listModels ERROR:", error.localizedDescription) }
            config.reasoningEffort = .low
            let client = OpenAIClient(config: config, apiKey: key)
            let t0 = Date()
            var chunks = 0
            var text = ""
            do {
                for try await delta in client.streamChat(history: [AIChatTurn(role: "user", text: "Responde solo: hola, el streaming funciona.")], snapshotJSON: "{}") {
                    chunks += 1
                    text += delta
                }
                print("stream OK: \(chunks) chunks in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s →", text.prefix(80))
            } catch { print("stream ERROR:", error.localizedDescription) }
            done.signal()
        }
        done.wait()
    }

    /// `--accounts-dump [--usage]`: what the account store sees. Read-only; prints no token, ever.
    static func accountsDump(readUsage: Bool) {
        let vault = AccountVault(directory: JSONStore().directory)
        func mask(_ email: String) -> String {
            let parts = email.split(separator: "@", maxSplits: 1)
            return parts.count == 2 ? "\(parts[0].prefix(2))…@\(parts[1])" : "…"
        }
        let live = vault.liveIdentity()
        let liveCredentials = vault.liveCredentials()
        print("en uso: \(live.map { mask($0.email) } ?? "nadie") · credencial legible: \(ClaudeCredential.isLogin(liveCredentials)) · token caduca: \(ClaudeCredential.expiresAt(liveCredentials).map { "\($0)" } ?? "—")")
        print("config: \(Fmt.tilde(vault.configPath))")
        print("almacén propio: \(vault.accounts().count) cuentas")
        for account in vault.accounts() {
            let saved = vault.credentials(for: account)
            print("  \(mask(account.email)) [\(account.agent)] legible: \(ClaudeCredential.isLogin(saved)) · caduca: \(ClaudeCredential.expiresAt(saved).map { "\($0)" } ?? "—")")
        }
        let preview = vault.legacyPreview()
        print("claude-swap: \(preview.count) cuentas")
        for item in preview {
            print("  \(item.number) \(mask(item.email)) legible: \(item.readable) · caduca: \(item.tokenExpires.map { "\($0)" } ?? "—")")
        }
        guard readUsage, let token = ClaudeCredential.accessToken(liveCredentials) else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            switch await ClaudeOAuth.usage(accessToken: token) {
            case .success(let windows):
                for window in windows { print("  límite \(window.name): \(Int(window.percent))% · reinicia \(window.resetsAt.map { "\($0)" } ?? "—")") }
            case .failure(let failure): print("  uso no disponible: \(failure)")
            }
            done.signal()
        }
        done.wait()
    }

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    static func command(_ name: String, json: Bool) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            switch name {
            case "mcp":
                await MCPServer.standard(version: version).serve()
            case "status":
                let (snapshot, system) = await Reports.sample()
                let status = Reports.status(snapshot, system)
                if json { print(Reports.json(status)); return }
                let heaviest = status["heaviest"] as? [String: Any]
                print("RAM \(status["memory_used_gb"] ?? 0) / \(status["memory_total_gb"] ?? 0) GB (\(status["memory_percent"] ?? 0)%) · pressure \(status["pressure"] ?? "") · swap \(status["swap_used_gb"] ?? 0) GB · CPU \(status["cpu_percent"] ?? 0)% · disk free \(status["disk_free_gb"] ?? 0) GB")
                if let name = heaviest?["name"] { print("heaviest: \(name) \(heaviest?["memory_gb"] ?? 0) GB · \(status["listening_ports"] ?? 0) ports · \(status["headless_browsers"] ?? 0) headless browsers") }
            case "top":
                let rows = Reports.top(await Reports.sample().0)
                print(json ? Reports.json(rows) : Reports.table(rows, columns: ["name", "kind", "memory_gb", "cpu_percent", "processes", "ports"]))
            case "ports":
                let rows = Reports.ports(await Reports.sample().0)
                print(json ? Reports.json(rows) : Reports.table(rows, columns: ["port", "address", "process", "pid", "owner"]))
            case "agents":
                let usage = await AgentUsageScanner().scan(days: 7, env: ProcessInfo.processInfo.environment)
                let rows = Reports.agents(usage, prices: PriceTable.load(directory: JSONStore().directory))
                print(json ? Reports.json(rows) : Reports.table(rows, columns: ["agent", "tokens_today", "tokens_7_days", "responses_7_days", "list_price_usd_7_days"]))
            case "today":
                let digest = await DailyDigests.load(day: AgentUsageReport.dayString(Date()), env: ProcessInfo.processInfo.environment,
                                                     prices: PriceTable.load(directory: JSONStore().directory))
                print(json ? Reports.json(DailyDigests.report(digest)) : DailyDigests.markdown(digest))
            case "branches":
                let recent = Date().addingTimeInterval(-14 * 86_400)
                let repos = await GitWork.scan(folders: SessionLibrary.list().filter { $0.modified >= recent }.map(\.folder))
                let rows = Reports.branches(repos)
                print(json ? Reports.json(rows) : Reports.table(rows, columns: ["repository", "branch", "worktree", "uncommitted", "ahead", "behind", "size_gb"]))
            case "sessions":
                let all = SessionLibrary.list()
                let query = CommandLine.arguments.dropFirst(2).first { !$0.hasPrefix("--") }
                var rows: [[String: Any]] = []
                for entry in all {
                    var row: [String: Any] = ["agent": entry.agent, "title": entry.title, "folder": entry.folder, "session": entry.sessionID,
                                              "last_used": ISO8601DateFormatter().string(from: entry.modified)]
                    if let branch = entry.branch { row["branch"] = branch }
                    if let query {
                        guard let hit = SessionLibrary.search(query, in: entry) else { continue }
                        row["match"] = hit.snippet
                        row["mentions"] = hit.count
                    }
                    rows.append(row)
                    if rows.count >= (query == nil ? 30 : 20) { break }
                }
                print(json ? Reports.json(rows) : Reports.table(rows, columns: ["agent", "last_used", "folder", "title"] + (query == nil ? [] : ["match"])))
            default:
                print("""
                devdeck \(version)

                  devdeck status   memory, swap, CPU, disk and what uses the most
                  devdeck top      what is using memory and CPU, by origin
                  devdeck ports    listening ports and who owns them
                  devdeck agents   tokens each coding agent spent (today and 7 days)
                  devdeck sessions [text]   past agent sessions, or the ones where that text was said
                  devdeck branches          branches and worktrees of the repositories agents worked in
                  devdeck today             today per project: tokens, list price, sessions and commits
                  devdeck mcp      Model Context Protocol server over stdio (read-only tools)

                Add --json for machine-readable output. With no command, the app opens.
                """)
            }
        }
        done.wait()
    }

    static func dump() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let sampler = Sampler()
            _ = await sampler.sample()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let (snap, sys) = await sampler.sample()
            print("RAM \(Fmt.bytes(sys.memUsed)) / \(Fmt.bytes(sys.memTotal)) · presión \(sys.pressureLabel) · swap \(Fmt.bytes(sys.swapUsed)) · CPU \(Fmt.percent(sys.cpuPercent)) · disco libre \(Fmt.bytes(sys.diskFree))")
            for g in snap.groups.prefix(30) {
                let ports = g.ports.map { String($0.port) }.joined(separator: ",")
                print("[\(g.kind.rawValue)] \(g.name) — \(Fmt.bytes(g.memoryBytes)), CPU \(Fmt.percent(g.cpuPercent)), \(g.processCount) procs\(ports.isEmpty ? "" : ", puertos \(ports)")")
                for s in g.services { print("    servicio \(s.rootPid): \(s.label) [\(s.framework ?? "-")] \(Fmt.bytes(s.memoryBytes)) puertos=\(s.ports)") }
                if !g.origins.isEmpty { print("    lanzados por: \(g.origins)") }
            }
            var listening: [Int32: [UInt16]] = [:]
            for binding in snap.ports { listening[binding.pid, default: []].append(binding.port) }
            for item in AgentLeftovers.find(processes: snap.processes, listening: listening) {
                print("[resto:\(item.kind.rawValue)] \(item.rootPid) \(item.command) — \(Fmt.bytes(item.memoryBytes)), \(item.pids.count) procs, \(Fmt.duration(since: item.since))\(item.ports.isEmpty ? "" : ", puertos \(item.ports)")")
            }
            done.signal()
        }
        done.wait()
    }
}

/// Draws the app icon (used by scripts/bundle.sh to build AppIcon.icns).
@MainActor
enum IconRenderer {
    static func render(to path: String) {
        let view = LogoArt()
        let renderer = ImageRenderer(content: view.frame(width: 1024, height: 1024))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// `DevDeck.app/Contents/MacOS/DevDeck --notify-test`: prints what macOS says about notifications for this bundle.
@MainActor
enum NotifyProbe {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let center = UNUserNotificationCenter.current()
        print("bundle:", Bundle.main.bundleIdentifier ?? "nil", Bundle.main.bundleURL.path)
        center.getNotificationSettings { settings in
            print("status before:", settings.authorizationStatus.rawValue, "alertStyle:", settings.alertStyle.rawValue)
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                print("granted:", granted, "error:", error.map { "\($0)" } ?? "none")
                let content = UNMutableNotificationContent()
                content.title = "DevDeck"
                content.body = "Prueba de notificación"
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                    print("add error:", error.map { "\($0)" } ?? "none")
                    center.getNotificationSettings { after in
                        print("status after:", after.authorizationStatus.rawValue)
                        exit(0)
                    }
                }
            }
        }
        app.run()
    }
}
