import DevDeckCore
import SwiftUI

struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var destructive = false
    let run: () -> Void
}

struct PaletteItem: Identifiable {
    let id: String
    let section: String
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var accessory: String = ""
    var primaryLabel: String = L("Abrir")
    let run: () -> Void
    var actions: [PaletteAction] = []
}

enum PaletteMode { case home, chat, diagnosis }

/// Raycast-style command palette: search, keyboard navigation, live AI answers and an action panel (⌘K).
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    var floating: Bool

    @State private var query = ""
    @State private var selection = 0
    @State private var mode: PaletteMode = .home
    @State private var showActions = false
    @State private var actionSelection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            searchBar(list)
            Rectangle().fill(Theme.ink(0.08)).frame(height: 1)
            Group {
                switch mode {
                case .home: resultsList(list)
                case .chat: AgentConversationView()
                case .diagnosis: DiagnosisPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.ink(0.08)).frame(height: 1)
            footer(list)
        }
        .frame(width: floating ? 780 : nil, height: floating ? 540 : nil)
        .modifier(PaletteSurface(floating: floating))
        .overlay(alignment: .bottomTrailing) {
            if showActions, list.indices.contains(selection) {
                ActionsPanel(item: list[selection], selection: actionSelection)
                    .padding(.trailing, 12)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: showActions)
        .onAppear {
            focused = true
            if model.agentRunning || !model.pendingApprovals.isEmpty || Date().timeIntervalSince(model.chatRequested) < 2 { mode = .chat }
        }
        .onChange(of: model.chatToken) { query = ""; showActions = false; mode = .chat }
        .onChange(of: model.paletteToken) {
            query = ""
            selection = 0
            showActions = false
            if mode == .diagnosis && !model.aiBusy { mode = .home }
            // Reopened while the copilot works or waits for a decision: go straight back to it.
            if model.agentRunning || !model.pendingApprovals.isEmpty { mode = .chat }
            focused = true
        }
        .onChange(of: query) { selection = 0; showActions = false }
    }

    // MARK: Search bar

    private func searchBar(_ list: [PaletteItem]) -> some View {
        HStack(spacing: 12) {
            if mode != .home {
                Button { goHome() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Theme.ink(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($focused)
                .onSubmit { submit(list) }
                .onKeyPress(.downArrow) { move(1, list); return .handled }
                .onKeyPress(.upArrow) { move(-1, list); return .handled }
                .onKeyPress(.escape) { escape(); return .handled }
                .onKeyPress(keys: [KeyEquivalent("k")], phases: .down) { press in
                    guard press.modifiers.contains(.command), mode == .home, list.indices.contains(selection),
                          !list[selection].actions.isEmpty else { return .ignored }
                    actionSelection = 0
                    showActions.toggle()
                    return .handled
                }
            if model.aiBusy || model.agentRunning { ProgressView().controlSize(.small) }
            if floating { Keycap(text: "esc") }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
    }

    private var placeholder: String {
        switch mode {
        case .home: return L("Pregunta a la IA o busca un comando, proyecto, puerto…")
        case .chat: return L("Pregunta de seguimiento…")
        case .diagnosis: return L("Pregunta sobre el diagnóstico…")
        }
    }

    // MARK: Results

    private func resultsList(_ list: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || list[index - 1].section != item.section {
                            Text(item.section)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.tertiaryText)
                                .padding(.horizontal, 12)
                                .padding(.top, index == 0 ? 6 : 12)
                                .padding(.bottom, 4)
                        }
                        PaletteRow(item: item, selected: index == selection)
                            .id(item.id)
                            .onTapGesture { selection = index; item.run() }
                    }
                    if list.isEmpty {
                        Text(L("Sin resultados")).foregroundStyle(Theme.tertiaryText).padding(20)
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) {
                if list.indices.contains(selection) { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(list[selection].id) } }
            }
        }
    }

    private func footer(_ list: [PaletteItem]) -> some View {
        HStack(spacing: 10) {
            AppGlyph(size: 16)
            Text("DevDeck").font(.system(.caption).weight(.semibold))
            Text("· \(model.aiEngineLabel)").font(.caption).foregroundStyle(Theme.tertiaryText)
            Spacer()
            switch mode {
            case .home:
                if list.indices.contains(selection) {
                    Text(list[selection].primaryLabel).font(.caption.weight(.medium))
                    Keycap(text: "↵")
                    if !list[selection].actions.isEmpty {
                        Rectangle().fill(Theme.ink(0.15)).frame(width: 1, height: 14)
                        Text(L("Acciones")).font(.caption.weight(.medium))
                        Keycap(text: "⌘K")
                    }
                }
            case .chat, .diagnosis:
                Text(L("Preguntar")).font(.caption.weight(.medium))
                Keycap(text: "↵")
                Rectangle().fill(Theme.ink(0.15)).frame(width: 1, height: 14)
                Text(L("Volver")).font(.caption.weight(.medium))
                Keycap(text: "esc")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    // MARK: Keyboard

    private func move(_ delta: Int, _ list: [PaletteItem]) {
        if showActions, list.indices.contains(selection) {
            let count = list[selection].actions.count
            actionSelection = max(0, min(count - 1, actionSelection + delta))
            return
        }
        guard mode == .home, !list.isEmpty else { return }
        selection = max(0, min(list.count - 1, selection + delta))
    }

    private func submit(_ list: [PaletteItem]) {
        if showActions, list.indices.contains(selection) {
            let actions = list[selection].actions
            if actions.indices.contains(actionSelection) { actions[actionSelection].run() }
            showActions = false
            return
        }
        switch mode {
        case .home:
            if list.indices.contains(selection) { list[selection].run() }
        case .chat, .diagnosis:
            let q = query
            query = ""
            mode = .chat
            model.startAgent(q)
        }
    }

    private func escape() {
        if showActions { showActions = false; return }
        if mode != .home { goHome(); return }
        if !query.isEmpty { query = ""; return }
        if floating { PaletteController.shared.hide() }
    }

    private func goHome() {
        mode = .home
        query = ""
        selection = 0
        focused = true
    }

    private func startChat(_ text: String) {
        query = ""
        mode = .chat
        model.startAgent(text)
    }

    private func startDiagnosis(_ focus: String?) {
        query = ""
        mode = .diagnosis
        Task { await model.diagnose(focus: focus) }
    }

    private func open(_ section: SidebarSection, project: String? = nil) {
        if let project { model.selectedProjectRoot = project }
        model.selectedSection = section
        if floating {
            PaletteController.shared.hide()
            Notifier.shared.onOpen?(section)
        }
    }

    // MARK: Items

    private var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var list: [PaletteItem] = []
        func matches(_ item: PaletteItem) -> Bool {
            q.isEmpty || item.title.lowercased().contains(q) || item.subtitle.lowercased().contains(q) || item.section.lowercased().contains(q)
        }

        if !q.isEmpty {
            let text = query
            list.append(PaletteItem(id: "ask", section: L("Inteligencia artificial"), icon: "sparkles", tint: Theme.accent(for: .copilot),
                                    title: L("Preguntar: “%@”", text), subtitle: L("Respuesta en vivo con el estado actual de tu Mac"),
                                    accessory: L("IA"), primaryLabel: L("Preguntar"), run: { startChat(text) }))
        }

        if !model.conversation.isEmpty {
            let resume = PaletteItem(id: "resume", section: L("Conversaciones"), icon: "bubble.left.and.text.bubble.right", tint: Theme.tint,
                                     title: L("Continuar la conversación actual"), subtitle: L("%@ preguntas", "\(model.conversation.filter { $0.kind == .user }.count)"),
                                     primaryLabel: L("Abrir"), run: { query = ""; mode = .chat })
            if matches(resume) { list.append(resume) }
            let fresh = PaletteItem(id: "new", section: L("Conversaciones"), icon: "plus.bubble", tint: Theme.tint, title: L("Nueva conversación"),
                                    subtitle: L("Guarda la actual en el historial"), primaryLabel: L("Nueva"), run: { model.resetConversation() })
            if matches(fresh) { list.append(fresh) }
        }
        for stored in model.history.prefix(q.isEmpty ? 5 : 30) where stored.id != model.conversationID {
            let item = PaletteItem(id: "h-\(stored.id)", section: L("Historial"), icon: "clock.arrow.circlepath", tint: Theme.tint, title: stored.title,
                                   subtitle: relative(stored.date), accessory: L("%@ preguntas", "\(stored.blocks.filter { $0.kind == "user" }.count)"),
                                   primaryLabel: L("Abrir"), run: { model.open(stored); query = ""; mode = .chat })
            if matches(item) { list.append(item) }
        }
        let suggestions: [(String, String)] = [
            (L("¿Por qué va lenta la Mac ahora mismo?"), "speedometer"),
            (L("Analiza mi swap: ¿qué lo llena y cómo lo bajo?"), "memorychip"),
            (L("¿Qué cachés puedo borrar sin romper nada?"), "trash"),
            (L("¿Qué están haciendo los agentes de IA ahora?"), "sparkles"),
        ]
        for (text, icon) in suggestions {
            let item = PaletteItem(id: "s-\(text)", section: L("Sugerencias"), icon: icon, tint: Theme.tint, title: text,
                                   subtitle: L("Preguntar a la IA"), accessory: L("IA"), primaryLabel: L("Preguntar"), run: { startChat(text) })
            if matches(item) { list.append(item) }
        }

        var commands: [PaletteItem] = [
            PaletteItem(id: "diag", section: L("Comandos"), icon: "stethoscope", tint: Theme.tint, title: L("Diagnosticar el sistema"),
                        subtitle: L("Hallazgos y acciones propuestas"), accessory: L("IA"), primaryLabel: L("Diagnosticar"), run: { startDiagnosis(nil) }),
            PaletteItem(id: "swap", section: L("Comandos"), icon: "memorychip", tint: Theme.tint, title: L("Analizar el swap"),
                        subtitle: "Swap \(Fmt.bytes(model.system.swapUsed)) · \(swapSummary)", accessory: L("IA"), primaryLabel: L("Analizar"),
                        run: { startDiagnosis(L("Analiza el swap a fondo: qué lo llena, si está activo o dormido, y qué cerrar para bajarlo.")) }),
        ]
        commands.append(PaletteItem(id: "game", section: L("Comandos"), icon: "gamecontroller", tint: Theme.tint,
                                    title: model.gameMode ? L("Salir del modo juego") : L("Activar modo juego"),
                                    subtitle: model.gameMode ? L("Reanuda lo que estaba en pausa") : model.gamePlanSummary(),
                                    primaryLabel: model.gameMode ? L("Salir") : L("Activar"),
                                    run: { if model.gameMode { model.exitGameMode() } else { model.enterGameMode() } }))
        let headless = model.snapshot.headlessBrowserCount
        if headless > 0, let group = model.snapshot.group(Classifier.headlessID) {
            commands.append(PaletteItem(id: "headless", section: L("Comandos"), icon: "rectangle.stack.badge.minus", tint: .orange,
                                        title: L("Cerrar %@ Chrome headless", "\(headless)"), subtitle: L("Libera %@", Fmt.bytes(group.memoryBytes)),
                                        primaryLabel: L("Cerrar"), run: { Task { await model.kill(group: group) } }))
        }
        let safeIdle = model.allProjectCaches.filter { $0.safe && $0.kind == .buildCache && model.services(using: $0).isEmpty }
        if !safeIdle.isEmpty {
            let total = safeIdle.reduce(0) { $0 + $1.sizeBytes }
            commands.append(PaletteItem(id: "clean", section: L("Comandos"), icon: "sparkles.rectangle.stack", tint: Theme.tint,
                                        title: L("Limpiar cachés de build de proyectos parados"), subtitle: L("%@ carpetas · %@", "\(safeIdle.count)", Fmt.bytes(total)),
                                        primaryLabel: L("Limpiar"), run: { Task { for e in safeIdle { await model.clean(e) } } }))
        }
        for section in SidebarSection.allCases where section != .copilot {
            commands.append(PaletteItem(id: "nav-\(section.rawValue)", section: L("Ir a"), icon: section.symbol, tint: Theme.accent(for: section),
                                        title: section.title, subtitle: L("Abrir en DevDeck"), accessory: L("Navegar"), run: { open(section) }))
        }
        list += commands.filter(matches)

        for group in model.snapshot.groups where group.kind == .project && !group.services.isEmpty {
            let ports = Set(group.ports.map(\.port)).sorted()
            var actions: [PaletteAction] = [
                PaletteAction(title: L("Reiniciar todos los servicios"), icon: "arrow.clockwise") {
                    Task { for s in group.services { await model.restart(service: s, in: group) } }
                },
                PaletteAction(title: L("Detener todo"), icon: "stop.circle", destructive: true) {
                    Task { for s in group.services { await model.stop(service: s, in: group) } }
                },
            ]
            for port in ports.prefix(3) {
                actions.append(PaletteAction(title: L("Abrir localhost:%@", "\(port)"), icon: "safari") { model.openInBrowser(port: port) })
            }
            if let root = group.projectRoot {
                actions.append(PaletteAction(title: L("Mostrar en Finder"), icon: "folder") { model.reveal(root) })
                actions.append(PaletteAction(title: L("Abrir Terminal aquí"), icon: "terminal") { model.openTerminal(at: root) })
            }
            let item = PaletteItem(id: group.id, section: L("Proyectos en ejecución"), icon: "folder.fill", tint: Theme.tint,
                                   title: group.name,
                                   subtitle: "\(Fmt.bytes(group.memoryBytes)) · \(L("%@ servicio(s)", "\(group.services.count)"))\(ports.isEmpty ? "" : " · " + ports.map { ":\($0)" }.joined(separator: " "))",
                                   accessory: group.frameworks.joined(separator: ", "), run: { open(.projects, project: group.projectRoot) },
                                   actions: actions)
            if matches(item) { list.append(item) }
        }

        for group in model.snapshot.groups.filter({ $0.kind != .project && $0.kind != .system }).prefix(6) {
            var actions: [PaletteAction] = []
            if group.killable {
                actions.append(PaletteAction(title: L("Cerrar %@", group.name), icon: "xmark.circle", destructive: true) {
                    Task { await model.kill(group: group) }
                })
            }
            let item = PaletteItem(id: "load-\(group.id)", section: L("Mayores consumidores"), icon: group.kind.symbol, tint: Color.kind(group.kind),
                                   title: group.name, subtitle: "\(Fmt.bytes(group.memoryBytes)) · CPU \(Fmt.percent(group.cpuPercent)) · \(L("%@ procesos", "\(group.processCount)"))",
                                   accessory: group.kind.title, run: { open(.load) }, actions: actions)
            if matches(item) { list.append(item) }
        }

        var seenPorts = Set<UInt16>()
        for binding in model.devPorts where seenPorts.insert(binding.port).inserted {
            var actions: [PaletteAction] = [PaletteAction(title: L("Abrir en el navegador"), icon: "safari") { model.openInBrowser(port: binding.port) }]
            if let root = binding.serviceRootPid, let found = model.snapshot.service(rootPid: root) {
                actions.append(PaletteAction(title: L("Reiniciar %@", found.1.label), icon: "arrow.clockwise") { Task { await model.restart(service: found.1, in: found.0) } })
                actions.append(PaletteAction(title: L("Detener"), icon: "stop.circle", destructive: true) { Task { await model.stop(service: found.1, in: found.0) } })
            }
            let item = PaletteItem(id: "port-\(binding.port)", section: L("Puertos"), icon: "point.3.connected.trianglepath.dotted", tint: Theme.tint,
                                   title: ":\(binding.port)  \(binding.groupName)", subtitle: binding.container.map { L("contenedor %@", $0) } ?? (binding.framework ?? binding.processName),
                                   accessory: Fmt.bytes(binding.memoryBytes), primaryLabel: L("Abrir en el navegador"),
                                   run: { model.openInBrowser(port: binding.port) }, actions: actions)
            if matches(item) { list.append(item) }
        }
        return list
    }

    private var swapSummary: String {
        let r = model.swapReport
        if r.thrashing { return "thrashing" }
        if r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 { return L("activo") }
        return model.system.swapUsed > 1 << 30 ? L("dormido") : L("casi sin uso")
    }
}

struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.icon, size: 24, active: selected)
            Text(item.title).font(.system(size: 14)).lineLimit(1)
            Text(item.subtitle).font(.system(size: 13)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            Spacer(minLength: 8)
            if !item.accessory.isEmpty {
                Text(item.accessory).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(selected ? Theme.ink(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct ActionsPanel: View {
    let item: PaletteItem
    let selection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.tertiaryText).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ForEach(Array(item.actions.enumerated()), id: \.element.id) { index, action in
                HStack(spacing: 10) {
                    Image(systemName: action.icon).frame(width: 16)
                    Text(action.title).lineLimit(1)
                    Spacer()
                    if index == selection { Keycap(text: "↵") }
                }
                .font(.system(size: 13))
                .foregroundStyle(action.destructive ? Theme.danger : Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(index == selection ? Theme.ink(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture { action.run() }
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.ink(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }
}

struct ChatTranscript: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.chat) { message in
                        if message.role == "user" {
                            Text(message.text)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(Theme.secondaryText).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(markdown(message.text + (message.streaming ? " ▍" : "")))
                                        .font(.system(size: 14))
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                    if message.streaming && message.text.isEmpty {
                                        Text(L("Pensando…")).font(.caption).foregroundStyle(Theme.tertiaryText)
                                    }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.chat.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct DiagnosisPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.aiBusy && model.diagnosis == nil {
                    HStack { ProgressView().controlSize(.small); Text(L("Analizando tu Mac…")).foregroundStyle(Theme.secondaryText) }
                }
                if let error = model.aiError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                }
                if let diagnosis = model.diagnosis {
                    DiagnosisContent(diagnosis: diagnosis, date: model.diagnosisDate)
                        .opacity(model.aiBusy ? 0.5 : 1)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DiagnosisContent: View {
    @Environment(AppModel.self) private var model
    let diagnosis: AIDiagnosis
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L("Diagnóstico"), systemImage: "sparkles").font(.system(.headline)).foregroundStyle(Theme.tint)
                Spacer()
                if let date { Text(date, style: .relative).font(.caption).foregroundStyle(Theme.tertiaryText) }
            }
            Text(diagnosis.summary).font(.system(size: 14)).lineSpacing(3)
            ForEach(diagnosis.findings, id: \.self) { finding in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: finding.severity == "critical" ? "exclamationmark.octagon.fill" : finding.severity == "warning" ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(finding.severity == "critical" ? Theme.danger : finding.severity == "warning" ? Theme.warning : Theme.link)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).font(.system(size: 13, weight: .semibold))
                        Text(finding.detail).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            if !diagnosis.actions.isEmpty {
                Text(L("ACCIONES PROPUESTAS")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiaryText).padding(.top, 4)
                ForEach(diagnosis.actions) { action in
                    ActionRow(action: action)
                }
            }
        }
    }
}

struct ActionRow: View {
    @Environment(AppModel.self) private var model
    let action: AIAction
    @State private var running = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Pill(text: action.risk == "low" ? L("riesgo bajo") : action.risk == "medium" ? L("riesgo medio") : L("riesgo alto"),
                 color: action.risk == "low" ? Theme.success : action.risk == "medium" ? Theme.warning : Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(describe(action)).font(.system(size: 13, weight: .medium))
                Text(action.reason).font(.caption).foregroundStyle(Theme.secondaryText)
                if let result = model.actionResults[action.id] {
                    Text("→ \(result)").font(.caption).foregroundStyle(Theme.link)
                }
            }
            Spacer()
            if model.actionResults[action.id] == nil {
                Button {
                    running = true
                    Task { _ = await model.apply(action); running = false }
                } label: {
                    if running { ProgressView().controlSize(.small) } else { Text(L("Aplicar")) }
                }
                .buttonStyle(.bordered)
                .disabled(running)
            }
        }
        .padding(12)
        .glass(cornerRadius: 12)
    }

    private func describe(_ action: AIAction) -> String {
        let target = model.unredact(action.target)
        switch action.type {
        case "kill_group": return L("Cerrar %@", model.snapshot.group(target)?.name ?? target)
        case "kill_process":
            let name = Int32(target).flatMap { model.snapshot.processes[$0]?.name } ?? L("proceso")
            return L("Matar %@ (PID %@)", name, target)
        case "restart_service":
            let label = Int32(target).flatMap { model.snapshot.service(rootPid: $0)?.1.label } ?? L("servicio %@", target)
            return L("Reiniciar %@", label)
        case "clean_cache":
            let size = model.cacheEntry(path: action.target).map { " (\(Fmt.bytes($0.sizeBytes)))" } ?? ""
            return L("Limpiar %@", Fmt.tilde(target)) + size
        case "set_memory_limit":
            return L("Avisar si %@ pasa de %d MB", model.snapshot.group(target)?.name ?? target, Int(action.value ?? 0))
        case "set_docker_memory": return L("Reducir la RAM de Docker a %d MB", Int(action.value ?? 0))
        case "run_tool": return Toolkit.recipe(target).map { L($0.title) } ?? target
        default: return action.title
        }
    }
}

/// Copilot section inside the main window: the same palette, embedded, plus autopilot settings.
struct CopilotView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HeroHeader(section: .copilot, title: L("Copiloto IA"), subtitle: L("Pregunta, diagnostica y actúa. Desde cualquier app: %@", model.settings.hotKeyLabel)) {
                Button { PaletteController.shared.show() } label: { Label(L("Abrir flotante"), systemImage: "macwindow.on.rectangle") }
                    .buttonStyle(.bordered)
            }
            HStack(alignment: .top, spacing: 12) {
                CommandPaletteView(floating: false)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                ConversationList()
                    .frame(width: 300)
            }
            HStack(spacing: 14) {
                Label(L("Piloto automático"), systemImage: "airplane").font(.system(.callout).weight(.semibold))
                Picker("", selection: $model.settings.ai.autopilot) {
                    ForEach(AutopilotMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                .onChange(of: model.settings.ai.autopilot) { model.saveSettings() }
                Text(model.settings.ai.autopilot.help).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            .padding(14)
            .glass(cornerRadius: 14)
            if let last = model.autopilotLog.first {
                Text(last).font(.caption.monospaced()).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
        }
        .padding(28)
    }
}

struct PaletteSurface: ViewModifier {
    let floating: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        if floating {
            content
                .floatingGlass(cornerRadius: 18)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .scaleEffect(shown ? 1 : 0.97)
                .opacity(shown ? 1 : 0)
                .onAppear { withAnimation(.spring(duration: 0.28, bounce: 0.2)) { shown = true } }
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
    }
}

/// Every saved conversation, always in view next to the copilot: the one in progress first.
struct ConversationList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Conversaciones").uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.4).foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button { model.resetConversation(); model.paletteToken = UUID() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(L("Nueva conversación")).disabled(model.conversation.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.history) { stored in
                        let current = stored.id == model.conversationID
                        let pending = stored.blocks.filter { $0.kind == "action" && ($0.approval ?? "pending") == "pending" }.count
                        Button {
                            if !current { model.open(stored) }
                            model.showConversation()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if current && model.agentRunning { ProgressView().controlSize(.mini) }
                                    Text(stored.title).font(.system(size: 13, weight: current ? .semibold : .regular)).lineLimit(2).multilineTextAlignment(.leading)
                                }
                                HStack(spacing: 6) {
                                    Text(relative(stored.date)).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                                    if current && model.agentRunning {
                                        Text(L("trabajando")).font(.system(size: 11)).foregroundStyle(Theme.success)
                                    } else if pending > 0 {
                                        Text(plural(pending, "%d decisión pendiente", "%d decisiones pendientes")).font(.system(size: 11)).foregroundStyle(Theme.warning)
                                    } else if !stored.blocks.contains(where: { $0.kind == "answer" }) {
                                        Text(L("sin respuesta")).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Theme.ink(current ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.history.isEmpty {
                        Text(L("Aquí aparecerán tus preguntas al copiloto, también las que hagas desde el lanzador."))
                            .font(.system(size: 12)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(cornerRadius: 12)
    }
}
