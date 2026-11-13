import AppKit
import DevDeckCore
import SwiftUI

/// A running app that looks like a game.
struct DetectedGame: Equatable {
    let name: String
    let pid: Int32
}

@MainActor
enum GameScanner {
    private static var cache: [String: (category: String?, gameMode: Bool)] = [:]

    /// The first regular app that looks like a game, preferring the one in front.
    static func find(settings: GameSettings) -> DetectedGame? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps.sorted(by: { ($0.processIdentifier == front ? 0 : 1) < ($1.processIdentifier == front ? 0 : 1) }) {
            guard let name = app.localizedName else { continue }
            let path = app.executableURL?.path ?? ""
            let bundle = app.bundleURL?.path ?? path
            if cache[bundle] == nil {
                let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
                let declares = (info?["LSSupportsGameMode"] as? Bool) == true || (info?["GCSupportsGameMode"] as? Bool) == true
                cache[bundle] = (info?["LSApplicationCategoryType"] as? String, declares)
            }
            let meta = cache[bundle]!
            if GameDetector.looksLikeGame(name: name, category: meta.category, declaresGameMode: meta.gameMode, path: path, settings: settings) {
                return DetectedGame(name: name, pid: app.processIdentifier)
            }
        }
        return nil
    }
}

@MainActor
extension AppModel {
    private var pausedFile: String { "paused.json" }

    /// Called on every sample: notices a game starting or ending and reacts as the user configured.
    func updateGameDetection() {
        guard !headless, settings.game.detect != "off" || gameStartedBy != nil else { return }
        let game = GameScanner.find(settings: settings.game)
        if gameMode {
            // Turned on because of a game: when the game is gone, everything comes back by itself.
            if let started = gameStartedBy, game?.name != started, !NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == started }) {
                exitGameMode(reason: L("%@ se cerró", started))
            }
            return
        }
        guard let game else { gameSuggestion = nil; return }
        if declinedGames.contains(game.name) { return }
        if settings.game.detect == "auto" {
            enterGameMode(because: game)
        } else if gameSuggestion != game {
            gameSuggestion = game
            let plan = gamePlanSummary()
            presentAlert(title: L("Parece que estás jugando a %@", game.name),
                         body: L("Recomendado: activar el modo juego. %@", plan), severity: .info,
                         actionLabel: L("Activar modo juego"), seconds: 45,
                         action: { [weak self] in self?.enterGameMode(because: game) },
                         onDismiss: { [weak self] in self?.declinedGames.insert(game.name) })
        }
    }

    /// Groups game mode would pause right now.
    func gamePauseCandidates(game: DetectedGame? = nil) -> [ProcessGroup] {
        var protected: Set<Int32> = [getpid()]
        if let game { protected.insert(game.pid) }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { protected.insert(front) }
        // Claude Code sessions that are busy right now are never paused.
        let busy = Set(liveSessions.filter(\.isBusy).map(\.pid))
        protected.formUnion(busy)
        return ProcessPauser.groupsToPause(snapshot.groups, settings: settings.game, protected: protected)
    }

    /// One sentence: what turning game mode on will do with the current settings.
    func gamePlanSummary() -> String {
        var parts: [String] = []
        let groups = gamePauseCandidates()
        if !groups.isEmpty {
            let memory = groups.reduce(0) { $0 + $1.memoryBytes }
            parts.append(L("Pausa %@ (%@) sin cerrarlos", groups.map(\.name).joined(separator: ", "), Fmt.bytes(memory)))
        }
        if settings.game.quietAlerts { parts.append(L("silencia los avisos no críticos")) }
        if settings.game.hideIsland { parts.append(L("oculta la isla")) }
        return parts.isEmpty ? "" : parts.joined(separator: ", ") + "."
    }

    func enterGameMode(because game: DetectedGame? = nil) {
        guard !gameMode else { return }
        gameMode = true
        gameStartedBy = game?.name
        gameSuggestion = nil
        islandAlert = nil
        deckOpen = false
        var paused: [PausedProcess] = []
        for group in gamePauseCandidates(game: game) { paused += ProcessPauser.pause(group, processes: snapshot.processes) }
        pausedProcesses = paused
        store.save(paused, pausedFile)
        gamePausedGroups = Array(Set(paused.map(\.group))).sorted()
        applyGameAppearance()
        pushAlert(AlertEvent(title: L("Modo juego activado"), message: gamePausedGroups.isEmpty ? (game?.name ?? "") : L("En pausa: %@", gamePausedGroups.joined(separator: ", ")), severity: .info))
        show(gamePausedGroups.isEmpty ? L("Modo juego activado") : L("Modo juego: %@ en pausa", gamePausedGroups.joined(separator: ", ")))
    }

    func exitGameMode(reason: String? = nil) {
        guard gameMode else { return }
        gameMode = false
        if let started = gameStartedBy { declinedGames.insert(started) }   // do not suggest it again for the same run of the game
        gameStartedBy = nil
        let resumed = resumePaused()
        applyGameAppearance()
        let detail = resumed > 0 ? L("%@ procesos reanudados", "\(resumed)") : ""
        pushAlert(AlertEvent(title: L("Modo juego desactivado"), message: [reason ?? "", detail].filter { !$0.isEmpty }.joined(separator: " · "), severity: .info))
        show(resumed > 0 ? L("Modo juego desactivado: %@ procesos reanudados", "\(resumed)") : L("Modo juego desactivado"))
    }

    /// Continues everything game mode paused (also what a previous run left paused, if the app quit unexpectedly).
    @discardableResult
    func resumePaused() -> Int {
        let pending = pausedProcesses.isEmpty ? (store.load(pausedFile, as: [PausedProcess].self) ?? []) : pausedProcesses
        var starts: [Int32: Date] = [:]
        for item in pending { if let process = snapshot.processes[item.pid] { starts[item.pid] = process.startTime } }
        let count = ProcessPauser.resume(pending, liveStarts: starts)
        pausedProcesses = []
        gamePausedGroups = []
        store.save([PausedProcess](), pausedFile)
        return count
    }

    /// Menu bar, island and Dock icon follow the mode.
    func applyGameAppearance() {
        guard !headless else { return }
        IslandController.shared.update(model: self)
        NSApp.applicationIconImage = gameMode ? LogoArt.image(game: true) : nil
    }
}

/// Strip at the top of the window while game mode is on.
struct GameModeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.gameMode {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 15)).foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.gameStartedBy.map { L("Modo juego · %@", $0) } ?? L("Modo juego")).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer()
                Button(L("Ajustar")) { model.selectedSection = .settings }.buttonStyle(.bordered)
                Button(L("Salir del modo juego")) { model.exitGameMode() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.success.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink(0.08)).frame(height: 1) }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !model.gamePausedGroups.isEmpty { parts.append(L("En pausa: %@", model.gamePausedGroups.joined(separator: ", "))) }
        if model.settings.game.quietAlerts { parts.append(L("avisos en silencio")) }
        if model.settings.game.hideIsland { parts.append(L("isla oculta")) }
        if model.settings.game.lowPower { parts.append(L("DevDeck en bajo consumo")) }
        return parts.isEmpty ? L("Sin cambios: revisa qué quieres que haga en Ajustes") : parts.joined(separator: " · ")
    }
}

/// Settings for game mode: when it turns on and what it pauses.
struct GameSettingsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var newGame = ""

    var body: some View {
        @Bindable var model = model
        Panel(L("Modo juego"), symbol: "gamecontroller") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.gameMode ? L("Activado") : L("Desactivado")).font(.system(.callout).weight(.medium))
                    Text(L("Deja la Mac para el juego: pausa lo que elijas sin cerrarlo, silencia avisos y esconde la isla. Al salir, todo sigue donde estaba."))
                        .font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420, alignment: .leading)
                Spacer()
                Button(model.gameMode ? L("Salir del modo juego") : L("Activar ahora")) {
                    if model.gameMode { model.exitGameMode() } else { model.enterGameMode() }
                }
                .buttonStyle(.borderedProminent)
            }
            row(L("Al detectar un juego"), L("Apps de la categoría Juegos, de Steam, Epic, GOG y otras tiendas, o las que añadas abajo")) {
                Picker("", selection: $model.settings.game.detect) {
                    Text(L("Recomendar")).tag("ask")
                    Text(L("Activar solo")).tag("auto")
                    Text(L("No detectar")).tag("off")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            }
            Divider().overlay(Theme.ink(0.08))
            Text(L("Qué se pausa mientras juegas").uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            toggle(L("Navegadores headless"), L("Los que dejan abiertos los agentes y los tests"), $model.settings.game.pauseHeadless)
            toggle(L("Agentes de IA que no estén trabajando"), L("Uno que esté ocupado nunca se pausa"), $model.settings.game.pauseIdleAgents)
            toggle(L("Servidores de desarrollo"), L("next dev, vite y similares; dejan de responder hasta que vuelvas"), $model.settings.game.pauseServers)
            toggle(L("Docker"), L("Congela la máquina virtual con todos sus contenedores"), $model.settings.game.pauseDocker)
            let candidates = model.gamePauseCandidates()
            Text(candidates.isEmpty ? L("Ahora mismo no hay nada de eso abierto.")
                 : L("Ahora mismo se pausarían: %@ (%@).", candidates.map(\.name).joined(separator: ", "), Fmt.bytes(candidates.reduce(0) { $0 + $1.memoryBytes })))
                .font(.caption).foregroundStyle(Theme.secondaryText)
            Divider().overlay(Theme.ink(0.08))
            toggle(L("Silenciar avisos"), L("Solo pasan las alertas críticas"), $model.settings.game.quietAlerts)
            toggle(L("Ocultar la isla"), L("Vuelve al salir del modo juego"), $model.settings.game.hideIsland)
            toggle(L("DevDeck en bajo consumo"), L("Mide cada 10 s y deja de leer registros de agentes y cachés"), $model.settings.game.lowPower)
            Divider().overlay(Theme.ink(0.08))
            row(L("Tratar como juego"), L("Para apps que no se detectan solas. Escribe el nombre como sale en el Dock")) {
                HStack(spacing: 6) {
                    TextField(L("Nombre de la app"), text: $newGame).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit(addGame)
                    Button(L("Añadir"), action: addGame).buttonStyle(.bordered).disabled(newGame.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !model.settings.game.extraGames.isEmpty || !model.settings.game.notGames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.settings.game.extraGames, id: \.self) { name in
                        chip(name, L("juego")) { model.settings.game.extraGames.removeAll { $0 == name } }
                    }
                    ForEach(model.settings.game.notGames, id: \.self) { name in
                        chip(name, L("no es un juego")) { model.settings.game.notGames.removeAll { $0 == name } }
                    }
                }
            }
        }
    }

    private func addGame() {
        let name = newGame.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !model.settings.game.extraGames.contains(name) else { return }
        model.settings.game.extraGames.append(name)
        model.settings.game.notGames.removeAll { $0 == name }
        newGame = ""
    }

    private func chip(_ name: String, _ kind: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .medium))
            Text(kind).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
    }

    private func toggle(_ title: String, _ subtitle: String, _ value: Binding<Bool>) -> some View {
        row(title, subtitle) { Toggle("", isOn: value).labelsHidden().toggleStyle(.switch) }
    }

    private func row<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.callout).weight(.medium))
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
            content()
        }
    }
}
