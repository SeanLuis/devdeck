import AppKit
import DevDeckCore
import Carbon.HIToolbox
import SwiftUI
import UserNotifications

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "DevDeck" }?.makeKeyAndOrderFront(nil)
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("DevDeck", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 720)
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
            done.signal()
        }
        done.wait()
    }
}

/// Draws the app icon (used by scripts/bundle.sh to build AppIcon.icns).
@MainActor
enum IconRenderer {
    static func render(to path: String) {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.12, blue: 0.22), Color(red: 0.20, green: 0.10, blue: 0.38)],
                                     startPoint: .top, endPoint: .bottom))
            // gauge arc: green (bottom-left) → red (bottom-right)
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(AngularGradient(colors: [.green, .yellow, .orange, .red], center: .center,
                                        startAngle: .degrees(43.2), endAngle: .degrees(316.8)),
                        style: StrokeStyle(lineWidth: 62, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: 600, height: 600)
            // needle
            Capsule()
                .fill(.white)
                .frame(width: 34, height: 250)
                .offset(y: -110)
                .rotationEffect(.degrees(38))
            Circle().fill(.white).frame(width: 96, height: 96)
            Circle().fill(Color(red: 0.16, green: 0.11, blue: 0.30)).frame(width: 36, height: 36)
            Text("dev")
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .offset(y: 285)
        }
        .frame(width: 1024, height: 1024)
        .padding(0)
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
