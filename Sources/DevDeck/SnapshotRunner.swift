import AppKit
import DevDeckCore
import SwiftUI

/// `DevDeck --snapshot <dir> [--with-ai]`: renders every screen to PNG offscreen (no display needed).
/// Used to verify the UI without clicking around.
@MainActor
enum SnapshotRunner {
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let demo = CommandLine.arguments.contains("--demo")
        let model = AppModel(headless: true, demo: demo)
        if let index = CommandLine.arguments.firstIndex(of: "--lang"), let language = AppLanguage(rawValue: CommandLine.arguments[index + 1]) {
            model.settings.language = language
            L10n.language = language
        }
        model.start()
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        Task { @MainActor in
            let wait = CommandLine.arguments.firstIndex(of: "--wait").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 12
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if CommandLine.arguments.contains("--with-ai") { await model.diagnose() }
            if let index = CommandLine.arguments.firstIndex(of: "--lang"), let language = AppLanguage(rawValue: CommandLine.arguments[index + 1]) {
                model.settings.language = language
                L10n.language = language
            }
            // `--game` shows the app as it looks in game mode.
            if CommandLine.arguments.contains("--game") {
                model.gameMode = true
                model.gameStartedBy = "Hades"
                model.gamePausedGroups = ["Chrome headless", "Codex"]
            }
            // `--pane ai` opens Settings on that section.
            // `--tab accounts` opens the Agents page on that group.
            if let index = CommandLine.arguments.firstIndex(of: "--tab") { UserDefaults.standard.set(CommandLine.arguments[index + 1], forKey: "agentsTab") }
            if let index = CommandLine.arguments.firstIndex(of: "--pane") { UserDefaults.standard.set(CommandLine.arguments[index + 1], forKey: "settingsPane") }
            if CommandLine.arguments.contains("--light") { model.settings.appearance = "light" } else { model.settings.appearance = "dark" }
            // A canned conversation so the agent UI can be checked without calling a model.
            // Canned texts in Spanish, or in English for any other language.
            let spanish = model.settings.language == .es
            func t(_ es: String, _ en: String) -> String { spanish ? es : en }
            var answer = AgentItem(kind: .answer, text: t(
                "Vas justo pero estable: **23,9 de 32 GB** en uso y el swap no crece.\n\n- **Docker** reserva 3,9 GB para 2 contenedores que usan 480 MB.\n- **Chrome headless**: 14 procesos que lanzaron los agentes suman 1,5 GB y ya nadie los usa.\n\nCerrar los headless libera memoria sin tocar nada en uso.",
                "Memory is tight but stable: **23.9 of 32 GB** in use and swap is not growing.\n\n- **Docker** reserves 3.9 GB for 2 containers that use 480 MB.\n- **Headless Chrome**: 14 processes launched by agents add up to 1.5 GB and nothing uses them any more.\n\nClosing the headless browsers frees memory without touching anything in use."))
            answer.revealed = answer.text.count
            var thought = AgentItem(kind: .thought, text: t("Reviso el swap y quién está fuera de RAM.", "Checking swap and who is out of RAM."))
            thought.seconds = 4
            var tool = AgentItem(kind: .tool, toolName: "swap_report")
            tool.toolState = .done
            var tool2 = AgentItem(kind: .tool, toolName: "inspect_group", toolArgument: "docker")
            tool2.toolState = .done
            var done = AgentItem(kind: .approval, action: AIAction(type: "run_tool", target: "docker-builder", value: nil,
                                                                   reason: t("La caché de build de Docker ocupa 9 GB y se regenera sola.", "Docker's build cache takes 9 GB and rebuilds itself."), risk: "medium"))
            done.approval = .done(L("Hecho: %@", L("Vaciar la caché de build")) + "\nTotal reclaimed space: 9.1GB")
            model.conversation = [
                AgentItem(kind: .user, text: t("Mi Mac va justa de memoria, ¿qué cierro?", "My Mac is short on memory, what should I close?")), thought,
                AgentItem(kind: .plan, plan: [PlanStep(title: t("Analizar el swap", "Analyze swap"), status: "done"),
                                              PlanStep(title: t("Inspeccionar Docker y los navegadores headless", "Inspect Docker and the headless browsers"), status: "done"),
                                              PlanStep(title: t("Proponer qué cerrar", "Propose what to close"), status: "active")]),
                tool, tool2, answer,
                AgentItem(kind: .approval, action: AIAction(type: "kill_group", target: Classifier.headlessID, value: nil,
                                                            reason: t("14 procesos sin uso ocupan 1,5 GB; los lanzaron los agentes.", "14 unused processes take 1.5 GB; agents launched them."), risk: "low")),
                AgentItem(kind: .approval, action: AIAction(type: "set_docker_memory", target: "docker", value: 4096,
                                                            reason: t("La VM de Docker reserva 3,9 GB para 2 contenedores que suman 480 MB.", "Docker's VM reserves 3.9 GB for 2 containers that add up to 480 MB."), risk: "medium")),
                done,
            ]
            await render(AgentConversationView().environment(model).background(Theme.background).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 780, height: 980), to: "\(outDir)/conversation.png")
            let sample = AppRelease(version: "0.2.0", notes: "## What's new\n\n- Token budgets per project, with alerts\n- Readers for **Cursor** and Aider\n- The island remembers the last board you used\n\n## Fixes\n\n- Lower CPU use while the window is open",
                                    pageURL: "https://github.com/\(Updates.repository)/releases", downloadURL: nil, publishedAt: Date().addingTimeInterval(-7200))
            await render(UpdateSheet(release: sample).environment(model).appLanguage(model.settings.language), size: CGSize(width: 560, height: 470), to: "\(outDir)/update.png")
            if let browser = model.snapshot.groups.first(where: { $0.kind == .browser }) ?? model.snapshot.groups.first(where: { $0.kind == .app }) {
                await render(ProcessTable(group: browser).padding(16).frame(maxHeight: .infinity, alignment: .top).background(Theme.surface).environment(model)
                    .appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 1000, height: 420), to: "\(outDir)/processes.png")
            }
            await render(SwapReliefSheet().environment(model).appLanguage(model.settings.language), size: CGSize(width: 580, height: 520), to: "\(outDir)/swap-relief.png")
            // The island in each of its states. `--notch` draws it as it hangs from a MacBook notch.
            if CommandLine.arguments.contains("--notch") { model.notchWidth = 190; model.notchHeight = 32 }
            let islandSize = CGSize(width: IslandController.size.width, height: IslandController.size.height)
            await render(IslandView().environment(model).background(Theme.background), size: islandSize, to: "\(outDir)/island-copilot-strip.png")
            model.deckOpen = true
            for tab in DeckTab.allCases {
                model.deckTab = tab.rawValue
                await render(IslandView().environment(model).background(Theme.background), size: islandSize, to: "\(outDir)/island-\(tab.rawValue).png")
            }
            model.deckOpen = false
            model.copilotDismissedAt = model.conversation.count
            await render(IslandView().environment(model).background(Theme.background), size: CGSize(width: islandSize.width, height: 120), to: "\(outDir)/island.png")
            // `--height N` renders taller pages (to see what is below the fold); `--only a,b` limits the sections.
            let height = CommandLine.arguments.firstIndex(of: "--height").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 900
            let only = CommandLine.arguments.firstIndex(of: "--only").map { Set(CommandLine.arguments[$0 + 1].split(separator: ",").map(String.init)) }
            for section in SidebarSection.allCases where only?.contains(section.rawValue) ?? true {
                model.selectedSection = section
                if section == .projects {
                    model.selectedProjectRoot = model.snapshot.groups.first { $0.kind == .project && !$0.services.isEmpty }?.projectRoot
                }
                await render(RootView().environment(model).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 1400, height: height), to: "\(outDir)/\(section.rawValue).png")
            }
            await render(MenuBarView().environment(model).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 384, height: 900), to: "\(outDir)/menubar.png")
            await render(MenuBarLabel().environment(model).padding(8).background(Color.black).environment(\.colorScheme, .dark), size: CGSize(width: 190, height: 36), to: "\(outDir)/menubar-label.png")
            await render(CommandPaletteView(floating: true).environment(model).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 780, height: 540), to: "\(outDir)/palette.png")
            print("snapshots written to \(outDir)")
            exit(0)
        }
        app.run()
    }

    static func render<V: View>(_ view: V, size: CGSize, to path: String, settle: Double = 1.5) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }

    // MARK: - Walkthrough

    /// One stop of the walkthrough: where the pointer goes, and what the app shows after the click.
    struct Stop {
        let point: CGPoint
        let section: SidebarSection
        var tab: String?
    }

    /// `DevDeck --record <dir>`: a walkthrough of the real interface on the demo machine, as numbered PNG frames
    /// meant for 12 frames per second. The pointer travels to each control, clicks, and the app answers.
    /// Nothing is read from this Mac, so the frames can be published.
    static func record(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel(headless: true, demo: true)
        model.settings.language = .en
        L10n.language = .en
        model.settings.appearance = "dark"
        model.start()
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let size = CGSize(width: 1400, height: 900)
        // Points measured on the rendered window (sidebar rows and the tabs of the Agents page).
        let stops: [Stop] = [
            Stop(point: CGPoint(x: 74, y: 122), section: .overview),
            Stop(point: CGPoint(x: 66, y: 182), section: .history),
            Stop(point: CGPoint(x: 70, y: 301), section: .projects),
            Stop(point: CGPoint(x: 72, y: 331), section: .agents, tab: "activity"),
            Stop(point: CGPoint(x: 452, y: 105), section: .agents, tab: "accounts"),
            Stop(point: CGPoint(x: 566, y: 105), section: .agents, tab: "usage"),
            Stop(point: CGPoint(x: 94, y: 450), section: .rules),
            Stop(point: CGPoint(x: 74, y: 122), section: .overview),
        ]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            model.selectedProjectRoot = model.snapshot.groups.first { $0.kind == .project && !$0.services.isEmpty }?.projectRoot
            var frame = 0
            var pointer = CGPoint(x: 700, y: 520)
            func shoot(_ pressed: Bool, settle: Double) async {
                let view = RootView().environment(model).appAppearance("dark").appLanguage(.en)
                    .overlay(alignment: .topLeading) { PointerMark(pressed: pressed).offset(x: pointer.x, y: pointer.y) }
                await render(view, size: size, to: String(format: "%@/f%04d.png", outDir, frame), settle: settle)
                frame += 1
            }
            UserDefaults.standard.set("activity", forKey: "agentsTab")
            model.selectedSection = .overview
            for _ in 0..<10 { await shoot(false, settle: frame == 0 ? 1.5 : 0.12) }
            for stop in stops.dropFirst() {
                // Travel: ease in and out over ten frames.
                let from = pointer
                for step in 1...10 {
                    let t = Double(step) / 10, eased = t * t * (3 - 2 * t)
                    pointer = CGPoint(x: from.x + (stop.point.x - from.x) * eased, y: from.y + (stop.point.y - from.y) * eased)
                    await shoot(false, settle: 0.12)
                }
                await shoot(true, settle: 0.12)
                await shoot(true, settle: 0.12)
                if let tab = stop.tab { UserDefaults.standard.set(tab, forKey: "agentsTab") }
                model.selectedSection = stop.section
                // The new page: one settled frame, then time to read it.
                await shoot(false, settle: 0.9)
                for _ in 0..<19 { await shoot(false, settle: 0.12) }
            }
            print("\(frame) frames written to \(outDir)")
            exit(0)
        }
        app.run()
    }
}

/// The pointer drawn over the walkthrough frames, with a ring while it clicks.
private struct PointerMark: View {
    let pressed: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if pressed { Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2).frame(width: 30, height: 30).offset(x: -13, y: -13) }
            Image(systemName: "cursorarrow").font(.system(size: 19, weight: .regular)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
        }
        .allowsHitTesting(false)
    }
}
