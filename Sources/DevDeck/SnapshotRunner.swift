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
            await render(MenuBarView().environment(model).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 384, height: 760), to: "\(outDir)/menubar.png")
            await render(CommandPaletteView(floating: true).environment(model).appAppearance(model.settings.appearance).appLanguage(model.settings.language), size: CGSize(width: 780, height: 540), to: "\(outDir)/palette.png")
            print("snapshots written to \(outDir)")
            exit(0)
        }
        app.run()
    }

    static func render<V: View>(_ view: V, size: CGSize, to path: String) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
