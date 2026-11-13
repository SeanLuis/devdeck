import DevDeckCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pastedKey = ""
    @State private var editingKey = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var showAdvanced = false
    @State private var pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .top, spacing: 0) {
            // Categories on the left, one at a time on the right.
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Ajustes")).font(.system(size: 22, weight: .semibold)).padding(.horizontal, 10).padding(.bottom, 12)
                ForEach(SettingsPane.allCases) { item in
                    Button { pane = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                                .foregroundStyle(item == pane ? Color.primary : Theme.secondaryText)
                            Text(item.title).font(.system(size: 13, weight: item == pane ? .medium : .regular))
                            Spacer(minLength: 0)
                            if item == .updates, model.pendingUpdate != nil { Circle().fill(Theme.link).frame(width: 6, height: 6) }
                            if item == .game, model.gameMode { Circle().fill(Theme.success).frame(width: 6, height: 6) }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Theme.ink(item == pane ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.horizontal, 12)
            .frame(width: 210)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.ink(0.07)).frame(width: 1) }

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.title).font(.system(size: 18, weight: .semibold))
                    Text(pane.summary).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                switch pane {
                case .general:
                Panel(L("Apariencia"), symbol: "paintbrush") {
                    row(L("Idioma"), L("De la aplicación y de las respuestas del copiloto")) {
                        Picker("", selection: $model.settings.language) {
                            ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    row(L("Tema"), L("Claro, oscuro o el del sistema")) {
                        Picker("", selection: $model.settings.appearance) {
                            Text(L("Sistema")).tag("system")
                            Text(L("Claro")).tag("light")
                            Text(L("Oscuro")).tag("dark")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    row(L("Iconos de apps y agentes"), L("Usa el icono real de cada aplicación instalada, en color o en gris, o solo símbolos")) {
                        Picker("", selection: $model.settings.iconStyle) {
                            Text(L("Color")).tag("color")
                            Text(L("Gris")).tag("mono")
                            Text(L("Símbolos")).tag("symbols")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                }
                case .ai:
                Panel(L("Inteligencia artificial"), symbol: "sparkles") {
                    VStack(spacing: 8) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            ProviderRow(provider: provider, selected: model.settings.ai.provider == provider,
                                        available: model.availableProviders.contains(provider)) {
                                model.settings.ai.provider = provider
                                model.settings.ai.providerChosen = true
                            }
                        }
                    }
                    Divider().overlay(Theme.ink(0.08))
                    switch model.settings.ai.provider {
                    case .claudeCode:
                        row(L("Modelo del copiloto"), L("El que responde cuando preguntas. Sonnet equilibra calidad y rapidez; Opus es el más capaz y el más lento")) {
                            Picker("", selection: $model.settings.ai.claudeModel) {
                                ForEach(["haiku", "sonnet", "opus", "default"], id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 240)
                        }
                        row(L("Modelo de los análisis automáticos"), L("Los que saltan solos con una alerta. Haiku responde en segundos y gasta poco")) {
                            Picker("", selection: $model.settings.ai.claudeAutoModel) {
                                ForEach(["haiku", "sonnet", "opus"], id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 240)
                        }
                    case .codex:
                        row(L("Modelo de Codex"), L("Vacío o “default” usa el de tu configuración")) {
                            TextField("default", text: $model.settings.ai.codexModel).textFieldStyle(.roundedBorder).frame(width: 240)
                        }
                    case .openAI:
                        keyRow
                        if let status = model.aiKeyStatus {
                            Label(status, systemImage: status.hasPrefix(String(L("Conectado · %@ modelos disponibles", "").prefix(6))) ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(status.hasPrefix(String(L("Conectado · %@ modelos disponibles", "").prefix(6))) ? Theme.success : Theme.warning)
                        }
                        row(L("Modelo"), L("El que responde diagnósticos y preguntas")) {
                            if model.settings.ai.availableModels.isEmpty {
                                TextField("gpt-6-luna", text: $model.settings.ai.model).textFieldStyle(.roundedBorder).frame(width: 240)
                            } else {
                                Picker("", selection: $model.settings.ai.model) {
                                    ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 240)
                            }
                        }
                    }
                    if model.settings.ai.provider == .openAI {
                    row(L("Razonamiento"), L("Más alto = más preciso pero más lento")) {
                        Picker("", selection: $model.settings.ai.reasoningEffort) {
                            ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    }
                    row(L("Piloto automático"), model.settings.ai.autopilot.help) {
                        Picker("", selection: $model.settings.ai.autopilot) {
                            ForEach(AutopilotMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)
                    }
                    row(L("Diagnóstico automático en alertas"), L("Cuando salta una alerta crítica, la IA la explica sola")) {
                        HStack {
                            Toggle("", isOn: $model.settings.ai.autoDiagnoseOnAlerts).labelsHidden().toggleStyle(.switch)
                            Stepper(L("cada %@ min como máximo", "\(Int(model.settings.ai.autoDiagnoseEveryMinutes))"),
                                    value: $model.settings.ai.autoDiagnoseEveryMinutes, in: 1...60, step: 1)
                                .disabled(!model.settings.ai.autoDiagnoseOnAlerts)
                        }
                    }
                    row(L("Acciones por diagnóstico"), L("Máximo de acciones que puede proponer")) {
                        Stepper("\(model.settings.ai.maxActions)", value: $model.settings.ai.maxActions, in: 1...10)
                    }
                    row(L("Privacidad"), L("Rutas con ~, tokens y claves siempre se enmascaran; nunca se envían variables de entorno")) {
                        Toggle(L("Enviar líneas de comando (redactadas)"), isOn: $model.settings.ai.shareCommandLines).toggleStyle(.switch)
                    }
                    Divider().overlay(Theme.ink(0.08))
                    OwnUsagePanel()
                    DisclosureGroup(L("Avanzado"), isExpanded: $showAdvanced) {
                        row(L("Endpoint compatible"), L("API Responses de OpenAI o un gateway compatible")) {
                            TextField("https://api.openai.com/v1", text: $model.settings.ai.baseURL).textFieldStyle(.roundedBorder).frame(width: 320)
                        }
                        .padding(.top, 8)
                    }
                    .font(.callout)
                }
                case .island:
                Panel(L("Isla y lanzador"), symbol: "rectangle.topthird.inset.filled") {
                    row(L("Atajo del lanzador"), L("Abre el copiloto desde cualquier app. Haz clic y pulsa la combinación nueva")) {
                        HotKeyRecorder()
                    }
                    row(L("Isla en vivo"), L("Píldora arriba al centro. Al hacer clic abre tableros de sistema, agentes, cuentas y copiloto")) {
                        Picker("", selection: $model.settings.islandMode) {
                            Text(L("Siempre")).tag("always")
                            Text(L("Solo si pasa algo")).tag("auto")
                            Text(L("Apagada")).tag("off")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                        .onChange(of: model.settings.islandMode) { IslandController.shared.update(model: model) }
                    }
                    row(L("Tablero inicial de la isla"), L("El que se abre primero; se puede cambiar desde la propia isla")) {
                        Picker("", selection: $model.settings.deckTab) {
                            ForEach(DeckTab.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden().frame(width: 240)
                        .onChange(of: model.settings.deckTab) { model.deckTab = model.settings.deckTab }
                    }
                }
                case .game:
                GameSettingsPanel()
                case .notifications:
                Panel(L("Notificaciones"), symbol: "bell.badge") {
                    row("macOS", model.notificationsAllowed
                        ? L("Las alertas llegan como notificaciones del sistema.")
                        : L("macOS no deja a DevDeck mostrar notificaciones. Mientras tanto, las alertas aparecen en la isla.")) {
                        HStack(spacing: 8) {
                            Pill(text: model.notificationStatus, color: model.notificationsAllowed ? Theme.success : Theme.warning)
                            if !model.notificationsAllowed {
                                Button(L("Activar en Ajustes del Sistema")) { Notifier.shared.openSystemSettings() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    row(L("Avisos de alertas"), "") {
                        HStack {
                            Toggle("", isOn: $model.settings.notificationsEnabled).labelsHidden().toggleStyle(.switch)
                            Button(L("Enviar prueba")) {
                                model.notify(title: L("Aviso de prueba"), body: L("Así se ven las alertas de DevDeck."), severity: .info, force: true)
                                model.refreshNotificationStatus()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    row(L("Sugerir otra cuenta al acercarse al límite"), L("Cuando la cuenta en uso pasa de este uso y otra guardada tiene margen. Solo sugiere: el cambio lo confirmas tú.")) {
                        HStack {
                            Toggle("", isOn: $model.settings.suggestAccountSwitch).labelsHidden().toggleStyle(.switch)
                            Picker("", selection: $model.settings.accountSwitchPercent) {
                                ForEach([75.0, 80, 85, 90, 95], id: \.self) { Text("\(Int($0))%").tag($0) }
                            }
                            .labelsHidden().frame(width: 80).disabled(!model.settings.suggestAccountSwitch)
                        }
                    }
                    row(L("Avisar cuando un agente espera"), L("Cuando Claude Code termina un turno largo o se detiene a preguntar")) {
                        Toggle("", isOn: $model.settings.notifyAgentWaiting).labelsHidden().toggleStyle(.switch)
                    }
                }
                case .monitoring:
                Panel(L("Monitoreo"), symbol: "waveform.path.ecg") {
                    row(L("Frecuencia de muestreo"), L("Más rápido = gráficos más finos, un poco más de CPU")) {
                        Picker("", selection: $model.settings.sampleInterval) {
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                            Text("5 s").tag(5.0)
                            Text("10 s").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    row(L("Historial en gráficos"), "") {
                        Picker("", selection: $model.settings.historyMinutes) {
                            Text("15 min").tag(15.0)
                            Text("30 min").tag(30.0)
                            Text("60 min").tag(60.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    row(L("Abrir al iniciar sesión"), L("DevDeck queda en la barra de menú")) {
                        Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                            .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                    }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme.danger) }
                }
                case .projects:
                Panel(L("Dónde buscar proyectos"), symbol: "folder") {
                    ForEach(model.settings.projectRoots, id: \.self) { root in
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.link)
                            Text(Fmt.tilde(root))
                            Spacer()
                            Button { model.settings.projectRoots.removeAll { $0 == root } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        Button(L("Añadir carpeta…")) { addRoot() }.buttonStyle(.bordered)
                        Button(L("Buscar de nuevo")) { Task { await model.discoverProjects() } }.buttonStyle(.bordered)
                        Spacer()
                        Text(L("%@ proyectos", "\(model.discoveredProjects.count)")).foregroundStyle(Theme.secondaryText)
                    }
                }
                case .updates:
                Panel(L("Actualizaciones"), symbol: "arrow.down.circle") {
                    row(L("Versión %@", model.appVersion), updateStatus) {
                        HStack(spacing: 8) {
                            if let update = model.availableUpdate {
                                Button(L("Ver la %@", update.version)) { model.showUpdate = true }.buttonStyle(.borderedProminent)
                            }
                            Button {
                                Task { await model.checkForUpdates(manual: true) }
                            } label: {
                                if model.updateChecking { ProgressView().controlSize(.small) } else { Text(L("Buscar ahora")) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.updateChecking)
                        }
                    }
                    row(L("Buscar actualizaciones cada día"), L("Solo avisa. Nunca se instala nada sin que lo aceptes")) {
                        Toggle("", isOn: $model.settings.checkForUpdates).labelsHidden().toggleStyle(.switch)
                    }
                }
                case .about:
                Panel(L("Huella de DevDeck")) {
                    let me = model.snapshot.group(Classifier.selfGroupID)
                    HStack(spacing: 0) {
                        footprint(L("Memoria"), me.map { Fmt.bytes($0.memoryBytes) } ?? "—")
                        footprint("CPU", me.map { Fmt.percent($0.cpuPercent) } ?? "—")
                        footprint(L("Procesos"), me.map { "\($0.processCount)" } ?? "—")
                        footprint(L("En disco"), model.storageBytes > 0 ? Fmt.bytes(model.storageBytes) : "…")
                        footprint(L("Conversaciones"), "\(model.history.count)")
                    }
                    GroupMemoryChart(groupID: Classifier.selfGroupID).frame(height: 110)
                    HStack {
                        Text(L("Incluye los comandos que DevDeck lanza para medir (du, docker). Todo se guarda solo en este Mac."))
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Button(L("Borrar historial de conversaciones")) { model.deleteHistory() }.buttonStyle(.bordered)
                    }
                }
                .task { model.storageBytes = await CacheScanner.size(of: model.store.directory.path) }

                Panel(L("Datos"), symbol: "externaldrive") {
                    HStack {
                        Text(Fmt.tilde(model.store.directory.path)).font(.callout.monospaced())
                        Spacer()
                        Button(L("Abrir carpeta")) { NSWorkspace.shared.open(model.store.directory) }.buttonStyle(.bordered)
                    }
                    Text(L("La API key y los comandos recordados (con su entorno) se guardan aquí con permisos 600."))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .onChange(of: model.settings) { model.saveSettings() }
        .onAppear { model.refreshNotificationStatus(); model.refreshProviders() }
    }

    @ViewBuilder
    private var keyRow: some View {
        if let masked = model.storedKeyMasked, !editingKey {
            row(L("API key de OpenAI"), L("Guardada en este Mac")) {
                HStack(spacing: 8) {
                    Text(masked).font(.callout.monospaced()).padding(.horizontal, 10).padding(.vertical, 5).glass(cornerRadius: 8)
                    Button {
                        Task { await model.saveAndVerifyKey(nil) }
                    } label: {
                        if model.aiVerifying { ProgressView().controlSize(.small) } else { Text(L("Verificar")) }
                    }
                    .buttonStyle(.bordered)
                    Button(L("Cambiar")) { editingKey = true }.buttonStyle(.bordered)
                    Button(role: .destructive) { model.removeKey() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
        } else {
            row(L("API key de OpenAI"), L("Pégala y listo: se valida y se cargan tus modelos")) {
                HStack(spacing: 8) {
                    SecureField("sk-…", text: $pastedKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .onSubmit(save)
                    Button {
                        save()
                    } label: {
                        if model.aiVerifying { ProgressView().controlSize(.small) } else { Text(L("Guardar y verificar")) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingKey { Button(L("Cancelar")) { editingKey = false; pastedKey = "" }.buttonStyle(.borderless) }
                }
            }
        }
    }

    private var updateStatus: String {
        if let error = model.updateError { return error }
        if let update = model.availableUpdate { return L("Hay una versión nueva: %@", update.version) }
        if let date = model.lastUpdateCheck { return L("Al día · comprobado %@", relative(date)) }
        return L("Aún no se ha comprobado")
    }

    private var modelOptions: [String] {
        var list = model.settings.ai.availableModels
        if !list.contains(model.settings.ai.model) { list.insert(model.settings.ai.model, at: 0) }
        return list
    }

    private func save() {
        let key = pastedKey
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pastedKey = ""
        editingKey = false
        Task { await model.saveAndVerifyKey(key) }
    }

    private func row<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.callout).weight(.medium))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
            Spacer()
            content()
        }
    }

    private func footprint(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("No se pudo cambiar: %@", error.localizedDescription)
        }
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !model.settings.projectRoots.contains(url.path) { model.settings.projectRoots.append(url.path) }
            Task { await model.discoverProjects() }
        }
    }
}

struct ProviderRow: View {
    let provider: AIProvider
    let selected: Bool
    let available: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.primary : Theme.tertiaryText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title).font(.system(size: 13, weight: .medium))
                    Text(provider.detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(available ? L("disponible") : provider == .openAI ? L("falta la key") : L("no instalado"))
                    .font(.system(size: 11))
                    .foregroundStyle(available ? Theme.success : Theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.ink(selected ? 0.07 : 0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.ink(selected ? 0.22 : 0.07), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What DevDeck itself has spent on AI, in plain numbers.
struct OwnUsagePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let today = OwnUsage.shared.summary(lastDays: 1)
        let week = OwnUsage.shared.summary(lastDays: 7)
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Lo que gasta DevDeck").uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
            HStack(spacing: 0) {
                stat(L("Hoy"), today.total)
                stat(L("7 días"), week.total)
                stat(L("Tus preguntas · 7 días"), week.purposes["copilot"] ?? TokenCount())
                stat(L("Análisis automáticos · 7 días"), week.purposes["automatic"] ?? TokenCount())
            }
            Text(model.settings.ai.provider == .openAI
                 ? L("DevDeck solo usa IA cuando le preguntas al copiloto o cuando un análisis automático salta por una alerta; esas llamadas se cobran a tu API key. Leer el uso de tus agentes no gasta nada: sale de archivos de este Mac.")
                 : L("DevDeck solo usa IA cuando le preguntas al copiloto o cuando un análisis automático salta por una alerta; esas llamadas usan tu sesión del agente y cuentan para tu límite. Leer el uso de tus agentes no gasta nada: sale de archivos de este Mac."))
                .font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ title: String, _ tokens: TokenCount) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            Text(tokens.messages > 0 ? compact(tokens.billable) : "0").font(.system(size: 15, weight: .medium).monospacedDigit())
            Text(plural(tokens.messages, "%d consulta", "%d consultas")).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Sections of Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, ai, island, game, notifications, monitoring, projects, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .ai: return L("Inteligencia artificial")
        case .island: return L("Isla y lanzador")
        case .game: return L("Modo juego")
        case .notifications: return L("Notificaciones")
        case .monitoring: return L("Monitoreo")
        case .projects: return L("Proyectos")
        case .updates: return L("Actualizaciones")
        case .about: return L("Datos y consumo")
        }
    }

    var summary: String {
        switch self {
        case .general: return L("Idioma, tema e iconos")
        case .ai: return L("Motor, modelos, piloto automático y lo que gasta DevDeck")
        case .island: return L("La píldora de arriba, sus tableros y el atajo global")
        case .game: return L("Cuándo se activa y qué pausa mientras juegas")
        case .notifications: return L("Avisos del sistema y de DevDeck")
        case .monitoring: return L("Frecuencia de muestreo, historial y arranque")
        case .projects: return L("Carpetas donde DevDeck busca tus proyectos")
        case .updates: return L("Versión instalada y versiones nuevas")
        case .about: return L("Lo que ocupa DevDeck y dónde guarda sus datos")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .island: return "rectangle.topthird.inset.filled"
        case .game: return "gamecontroller"
        case .notifications: return "bell"
        case .monitoring: return "waveform.path.ecg"
        case .projects: return "folder"
        case .updates: return "arrow.down.circle"
        case .about: return "externaldrive"
        }
    }
}
