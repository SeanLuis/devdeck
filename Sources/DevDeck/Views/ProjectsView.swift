import Charts
import DevDeckCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var namingProfile = false
    @State private var profileName = ""

    var body: some View {
        @Bindable var model = model
        HSplitView {
            List(selection: $model.selectedProjectRoot) {
                Section(L("Perfiles")) {
                    ForEach(model.profiles) { profile in ProfileRow(profile: profile) }
                    Button { profileName = ""; namingProfile = true } label: {
                        Label(L("Guardar lo que corre como perfil"), systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(running.isEmpty)
                }
                Section(L("En ejecución")) {
                    ForEach(filtered.filter { running.contains($0.root) }) { project in
                        ProjectRow(project: project).tag(project.root)
                    }
                }
                Section(L("Todos (%@)", "\(filtered.count)")) {
                    ForEach(filtered.filter { !running.contains($0.root) }) { project in
                        ProjectRow(project: project).tag(project.root)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiaryText)
                    TextField(L("Buscar proyecto"), text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .glass(cornerRadius: 8)
                .padding(.horizontal, 12)
                .padding(.top, 40)
                .padding(.bottom, 6)
            }
            .background(Theme.background)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.ink(0.06)).frame(width: 1) }
            .frame(minWidth: 250, idealWidth: 290, maxWidth: 380)

            Group {
                if let root = model.selectedProjectRoot {
                    ProjectDetailView(root: root)
                        .id(root)
                } else {
                    EmptyHint(title: L("Elige un proyecto"), symbol: "folder",
                              message: L("Verás sus servidores, puertos, RAM, cachés y cómo arrancarlo o reiniciarlo."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(L("Nuevo perfil"), isPresented: $namingProfile) {
            TextField(L("Nombre del perfil"), text: $profileName)
            Button(L("Guardar")) { model.saveProfile(named: profileName) }
            Button(L("Cancelar"), role: .cancel) {}
        } message: {
            Text(L("Recordará los %d proyectos que corren ahora. Al aplicarlo los arranca y, si quieres, cierra el resto.", running.count))
        }
    }

    private var running: Set<String> { model.runningProjectRoots }

    private var filtered: [ProjectIdentity] {
        let list = model.projectsList
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.root.localizedCaseInsensitiveContains(search) }
    }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    let project: ProjectIdentity

    var body: some View {
        let group = model.snapshot.group(forProject: project.root)
        let cacheBytes = (model.projectCaches[project.root] ?? []).reduce(0) { $0 + $1.sizeBytes }
        HStack(spacing: 8) {
            Circle().fill(group == nil ? Color.secondary.opacity(0.3) : .green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).lineLimit(1)
                Text(verbatim: group.map(Self.summary)
                     ?? (cacheBytes > 0 ? L("%@ en cachés", Fmt.bytes(cacheBytes)) : Fmt.tilde((project.root as NSString).deletingLastPathComponent)))
                    .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            if let ports = group?.ports, !ports.isEmpty {
                Text(verbatim: ":\(ports[0].port)").font(.caption.monospacedDigit()).foregroundStyle(.blue)
            }
        }
    }

    static func summary(_ group: ProcessGroup) -> String {
        if group.services.isEmpty {
            let running = group.containers.filter(\.isRunning).count
            return L("solo Docker · %@ contenedor(es) · %@", "\(running)", Fmt.bytes(group.containerMemory))
        }
        return L("%@ · %@ servicio(s)", Fmt.bytes(group.memoryBytes), "\(group.services.count)")
    }
}

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    let root: String

    var body: some View {
        let group = model.snapshot.group(forProject: root)
        let name = group?.name ?? ProjectIdentity.named(root: root).name
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(name: name, group: group)
                ProjectInfraSection(root: root)
                if let group {
                    stats(group)
                    servicesSection(group)
                    Panel(L("Memoria (últimos 30 min)")) {
                        GroupMemoryChart(groupID: group.id).frame(height: 160).padding(6)
                    }
                    LimitEditor(groupID: group.id, name: group.name, currentMB: Fmt.mb(group.memoryBytes))
                    if !group.containers.isEmpty { containersSection(group.containers) }
                }
                launchSection(running: group != nil)
                ProjectWorkSection(root: root)
                ProjectCachesSection(root: root)
                logsSection
            }
            .padding(28)
        }
    }

    private func header(name: String, group: ProcessGroup?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.largeTitle.weight(.semibold))
                    Pill(text: group == nil ? L("parado") : L("corriendo"), color: group == nil ? .secondary : .green)
                    ForEach(group?.frameworks ?? [], id: \.self) { Pill(text: $0, color: .blue) }
                }
                Text(Fmt.tilde(root)).font(.callout).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button { model.reveal(root) } label: { Label("Finder", systemImage: "folder") }
                Button { model.openTerminal(at: root) } label: { Label("Terminal", systemImage: "terminal") }
                Button { Task { await model.openAgent(in: root) } } label: { Label("Claude Code", systemImage: "sparkle") }
                    .help(L("Abre Claude Code en esta carpeta, con la cuenta de este proyecto"))
                FolderAccountMenu(root: root)
                if let group, !group.services.isEmpty {
                    KillButton(title: L("¿Detener todo %@?", name), message: L("Se guardan los comandos para volver a arrancarlos."), label: L("Detener todo")) {
                        for s in group.services { await model.stop(service: s, in: group) }
                    }
                }
            }
        }
    }

    private func stats(_ group: ProcessGroup) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            StatCard(title: "RAM", value: Fmt.bytes(group.memoryBytes), subtitle: L("%@ procesos", "\(group.processCount)"), symbol: "memorychip",
                     fraction: Double(group.memoryBytes) / Double(max(model.system.memTotal, 1)))
            StatCard(title: "CPU", value: Fmt.percent(group.cpuPercent), subtitle: L("suma de procesos"), symbol: "cpu")
            StatCard(title: L("Puertos"), value: group.ports.isEmpty ? "—" : Set(group.ports.map(\.port)).sorted().map { ":\($0)" }.joined(separator: " "),
                     subtitle: L("%@ servicio(s)", "\(group.services.count)"), symbol: "point.3.connected.trianglepath.dotted")
            if !group.containers.isEmpty {
                StatCard(title: L("Contenedores"), value: "\(group.containers.filter(\.isRunning).count) / \(group.containers.count)",
                         subtitle: L("%@ dentro de Docker", Fmt.bytes(group.containerMemory)), symbol: "shippingbox")
            }
        }
    }

    private func servicesSection(_ group: ProcessGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Servicios")).font(.title3.weight(.semibold))
            if group.services.isEmpty {
                Text(L("Solo contenedores Docker para este proyecto.")).foregroundStyle(Theme.secondaryText)
            }
            ForEach(group.services) { service in
                ServiceCard(service: service, group: group)
            }
        }
    }

    private func containersSection(_ containers: [ContainerInfo]) -> some View {
        Panel(L("Contenedores Docker")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(containers) { c in
                    HStack {
                        Circle().fill(c.isRunning ? .green : .secondary.opacity(0.4)).frame(width: 7, height: 7)
                        Text(c.name).font(.callout.monospaced())
                        Text(c.image).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                        Spacer()
                        if !c.ports.isEmpty { Text(c.ports.map { ":\($0.hostPort)" }.joined(separator: " ")).font(.caption.monospacedDigit()).foregroundStyle(.blue) }
                        Text(c.memoryBytes.map(Fmt.bytes) ?? c.status).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func launchSection(running: Bool) -> some View {
        let saved = model.recipes[root] ?? []
        let scripts = PackageScripts.read(dir: root, projectRoot: root)
        if !saved.isEmpty || scripts != nil {
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    let plan = model.startPlan(root: root)
                    HStack(alignment: .firstTextBaseline) {
                        Text(running ? L("Arrancar otro servicio") : L("Arrancar")).font(.headline)
                        Spacer()
                        if plan.steps > 1 || plan.composeFile != nil {
                            if model.startingProjects.contains(root) { ProgressView().controlSize(.small) }
                            Button { Task { await model.startProject(root: root) } } label: { Label(L("Arrancar todo"), systemImage: "play.circle.fill") }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.startingProjects.contains(root))
                                .help(startAllHelp(plan))
                        }
                    }
                    if !saved.isEmpty, model.projectManifests[root] == nil {
                        Button { model.writeManifest(root: root) } label: { Label(L("Guardar como devdeck.json"), systemImage: "square.and.arrow.down") }
                            .controlSize(.small)
                            .help(L("Escribe en el proyecto un devdeck.json con estos comandos y puertos (sin variables de entorno), para levantarlo todo con un botón y compartirlo con el equipo"))
                    }
                    if !saved.isEmpty {
                        Text(L("Comandos recordados (mismo comando, carpeta y entorno con que corrían)")).font(.caption).foregroundStyle(Theme.secondaryText)
                        ForEach(saved) { recipe in
                            HStack {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.secondaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recipe.commandLine).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                                    Text("\(Fmt.tilde(recipe.cwd)) · \(recipe.ports.isEmpty ? "" : L("puertos %@", recipe.ports.map(String.init).joined(separator: ",")) + " · ")\(L("capturado %@", relative(recipe.capturedAt)))")
                                        .font(.caption).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                Button { model.launch(recipe) } label: { Label(L("Arrancar"), systemImage: "play.fill") }
                                Button { model.forget(recipe) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("Olvidar"))
                            }
                        }
                    }
                    if let scripts {
                        Text(L("Scripts de package.json (%@)", scripts.manager)).font(.caption).foregroundStyle(Theme.secondaryText)
                        FlowButtons(items: Array(scripts.preferredOrder.prefix(10))) { script in
                            model.launch(scripts.recipe(script: script, projectRoot: root, env: model.loginEnv))
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func startAllHelp(_ plan: ProjectStartPlan) -> String {
        var parts: [String] = []
        if plan.composeFile != nil { parts.append("docker compose up -d") }
        parts += plan.recipes.map(\.commandLine)
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var logsSection: some View {
        let runs = model.managedRuns.filter { $0.recipe.projectRoot == root }
        if let run = runs.first {
            Panel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L("Logs de %@", run.recipe.label)).font(.headline)
                        Pill(text: run.isRunning ? L("corriendo") : L("terminado"), color: run.isRunning ? .green : .secondary)
                        Spacer()
                        Button(L("Abrir archivo")) { NSWorkspace.shared.open(run.logURL) }.buttonStyle(.link)
                    }
                    LogTail(url: run.logURL)
                }
                .padding(6)
            }
        }
    }
}

struct ServiceCard: View {
    @Environment(AppModel.self) private var model
    let service: ServiceInfo
    let group: ProcessGroup

    var body: some View {
        let busy = model.busyPids.contains(service.rootPid)
        let nextCache = (model.projectCaches[group.projectRoot ?? ""] ?? []).first {
            $0.label == ".next" && model.services(using: $0).contains { $0.1.rootPid == service.rootPid }
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(service.framework ?? L("Proceso")).font(.headline)
                Text(service.label).font(.callout).foregroundStyle(Theme.secondaryText).lineLimit(1)
                Spacer()
                ForEach(service.ports, id: \.self) { port in
                    Button(":" + String(port)) { model.openInBrowser(port: port) }.buttonStyle(.link).font(.callout.monospacedDigit())
                }
            }
            Text(service.command).font(.caption.monospaced()).foregroundStyle(Theme.secondaryText).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 14) {
                Label(Fmt.bytes(service.memoryBytes), systemImage: "memorychip")
                Label(Fmt.percent(service.cpuPercent), systemImage: "cpu")
                Label(L("%@ procs", "\(service.pids.count)"), systemImage: "square.stack.3d.up")
                Label(uptime(service.startTime), systemImage: "clock")
                if model.managedRun(for: service.rootPid) != nil { Pill(text: L("lanzado por DevDeck"), color: .purple) }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.restart(service: service, in: group) } } label: { Label(L("Reiniciar"), systemImage: "arrow.clockwise") }
                        .help(L("Lo detiene y lo vuelve a lanzar con el mismo comando, carpeta y variables de entorno"))
                    if let cache = nextCache {
                        Button { Task { await model.restart(service: service, in: group, cleaning: [cache.path]) } } label: {
                            Label(L("Limpiar .next y reiniciar"), systemImage: "sparkles")
                        }
                        .help(L("Borra %@ de .next y reinicia", Fmt.bytes(cache.sizeBytes)))
                    }
                    KillButton(title: L("¿Detener %@?", service.label), message: L("El comando queda guardado para volver a arrancarlo."), label: L("Detener")) {
                        await model.stop(service: service, in: group)
                    }
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .padding(12)
        .glass(cornerRadius: 14)
    }
}

struct GroupMemoryChart: View {
    @Environment(AppModel.self) private var model
    let groupID: String

    var body: some View {
        let points = model.history(for: groupID, minutes: 30)
        let limit = model.limitRule(for: groupID)
        if points.count < 2 {
            EmptyHint(title: L("Recolectando datos…"), symbol: "chart.xyaxis.line", message: "")
        } else {
            Chart {
                ForEach(points, id: \.time) { p in
                    AreaMark(x: .value(L("Hora"), p.time), y: .value("MB", p.memMB))
                        .foregroundStyle(.blue.opacity(0.25).gradient)
                    LineMark(x: .value(L("Hora"), p.time), y: .value("MB", p.memMB))
                        .foregroundStyle(.blue)
                }
                if let limit, limit.enabled {
                    RuleMark(y: .value(L("Límite"), limit.threshold))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) { Text(L("límite")).font(.caption2).foregroundStyle(.red) }
                }
            }
            .chartYAxisLabel("MB")
        }
    }
}

struct LimitEditor: View {
    @Environment(AppModel.self) private var model
    let groupID: String
    let name: String
    let currentMB: Double
    @State private var limitGB: Double = 4
    @State private var action: RuleAction = .notify

    var body: some View {
        let rule = model.limitRule(for: groupID)
        Panel {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.needle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Límite de RAM")).font(.headline)
                    Text(rule.map { L("Activo: %@ GB → %@", String(format: "%.1f", $0.threshold / 1024), $0.action.title) } ?? L("Sin límite. Usa ahora %@ GB.", String(format: "%.1f", currentMB / 1024)))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Stepper(value: $limitGB, in: 0.5...24, step: 0.5) {
                    Text("\(String(format: "%.1f", limitGB)) GB").monospacedDigit()
                }
                Picker("", selection: $action) {
                    ForEach([RuleAction.notify, .restartServices, .killGroup, .askAI], id: \.self) { Text($0.title).tag($0) }
                }
                .frame(width: 230)
                Button(rule == nil ? L("Poner límite") : L("Actualizar")) {
                    model.setLimit(groupID: groupID, name: name, mb: limitGB * 1024, action: action)
                    model.show(L("Límite de %@ GB para %@", String(format: "%.1f", limitGB), name))
                }
                if rule != nil {
                    Button(L("Quitar")) { model.removeLimit(groupID: groupID) }
                }
            }
            .padding(6)
        }
        .onAppear {
            if let rule {
                limitGB = rule.threshold / 1024
                action = rule.action
            } else {
                limitGB = max(1, ((currentMB / 1024) * 1.5 * 2).rounded() / 2)
            }
        }
    }
}

struct ProjectCachesSection: View {
    @Environment(AppModel.self) private var model
    let root: String

    var body: some View {
        let entries = model.projectCaches[root] ?? []
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Cachés y carpetas pesadas")).font(.headline)
                    Spacer()
                    Text(Fmt.bytes(entries.reduce(0) { $0 + $1.sizeBytes })).font(.callout.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    Button {
                        Task {
                            let entries = await CacheScanner.scanProject(ProjectIdentity.named(root: root))
                            model.projectCaches[root] = entries
                            model.saveCacheReport()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L("Volver a medir"))
                }
                if entries.isEmpty {
                    Text(model.cacheScanProgress == nil ? L("Nada pesado (> 1 MB) encontrado.") : L("Midiendo… %@", model.cacheScanProgress ?? ""))
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                ForEach(entries) { entry in
                    CacheRow(entry: entry, showProject: false)
                }
            }
            .padding(6)
        }
    }
}

struct CacheRow: View {
    @Environment(AppModel.self) private var model
    let entry: CacheEntry
    var showProject = true

    var body: some View {
        let users = model.services(using: entry)
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .dependencies ? "shippingbox" : entry.kind == .virtualEnv ? "cube" : "tray.full")
                .foregroundStyle(entry.safe ? .green : .orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if showProject, let r = entry.projectRoot { Text((r as NSString).lastPathComponent).fontWeight(.medium) }
                    Text(entry.relativePath).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Pill(text: entry.kind.title, color: entry.safe ? .green : .orange)
                    if !users.isEmpty { Pill(text: L("en uso"), color: .blue) }
                }
                Text(L("%@ · para regenerar: %@", L(entry.note), L(entry.regenerate))).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            Text(Fmt.bytes(entry.sizeBytes)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 80, alignment: .trailing)
            Button { model.reveal(entry.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help(L("Mostrar en Finder"))
            if users.isEmpty {
                KillButton(title: L("¿Borrar %@?", entry.relativePath), message: "\(Fmt.bytes(entry.sizeBytes)). \(L(entry.regenerate)).", label: L("Limpiar")) {
                    await model.clean(entry)
                }
            } else {
                KillButton(title: L("¿Limpiar y reiniciar?"), message: L("Se detienen %@ servicio(s) que lo usan, se borra %@ (%@) y se vuelven a arrancar igual.", "\(users.count)", entry.relativePath, Fmt.bytes(entry.sizeBytes)), label: L("Limpiar y reiniciar")) {
                    await model.cleanAndRestart(entry)
                }
            }
        }
    }
}

struct FlowButtons: View {
    let items: [String]
    let action: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: { Label(item, systemImage: "play").lineLimit(1) }
            }
        }
    }
}

struct LogTail: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? L("(sin salida todavía)") : text)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 180)
        .padding(8)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Theme.ink(0.9))
        .task(id: url) {
            while !Task.isCancelled {
                if let handle = try? FileHandle(forReadingFrom: url) {
                    let size = (try? handle.seekToEnd()) ?? 0
                    try? handle.seek(toOffset: size > 12_000 ? size - 12_000 : 0)
                    let data = (try? handle.readToEnd()) ?? Data()
                    try? handle.close()
                    text = String(decoding: data, as: UTF8.self)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}

/// A saved way of working. Applying it shows first what it will start and close.
struct ProfileRow: View {
    @Environment(AppModel.self) private var model
    let profile: WorkProfile
    @State private var confirming = false
    @State private var applying = false

    var body: some View {
        let plan = model.profilePlan(profile)
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.secondaryText).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text(verbatim: plan.isEmpty ? L("activo") : plural(profile.projects.count, "%d proyecto", "%d proyectos"))
                    .font(.caption).foregroundStyle(plan.isEmpty ? Theme.success : Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            if applying { ProgressView().controlSize(.small) }
            else if !plan.isEmpty {
                Button { confirming = true } label: { Image(systemName: "play.fill") }.buttonStyle(.borderless).help(L("Aplicar perfil"))
            }
        }
        .contextMenu {
            Toggle(L("Cerrar los demás proyectos"), isOn: Binding(get: { profile.closeOtherProjects }, set: { value in
                var changed = profile; changed.closeOtherProjects = value; model.updateProfile(changed)
            }))
            Toggle(L("Cerrar los navegadores headless"), isOn: Binding(get: { profile.closeHeadless }, set: { value in
                var changed = profile; changed.closeHeadless = value; model.updateProfile(changed)
            }))
            Divider()
            Button(L("Eliminar perfil"), role: .destructive) { model.removeProfile(profile.id) }
        }
        .confirmationDialog(L("¿Aplicar el perfil “%@”?", profile.name), isPresented: $confirming) {
            Button(L("Aplicar perfil")) {
                applying = true
                Task { await model.apply(profile: profile); applying = false }
            }
        } message: {
            Text(summary(plan))
        }
    }

    private func summary(_ plan: WorkProfilePlan) -> String {
        func names(_ roots: [String]) -> String { roots.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") }
        var lines: [String] = []
        if !plan.start.isEmpty { lines.append(L("Arranca: %@", names(plan.start))) }
        if !plan.close.isEmpty { lines.append(L("Cierra: %@", names(plan.close))) }
        if plan.closeHeadless { lines.append(L("Cierra los navegadores headless")) }
        return lines.joined(separator: "\n")
    }
}

/// Which saved Claude Code account this project's agent work belongs to.
struct FolderAccountMenu: View {
    @Environment(AppModel.self) private var model
    let root: String

    var body: some View {
        let saved = model.accounts.accounts(of: "Claude Code").filter { $0.vaultID != nil }
        if !saved.isEmpty {
            let current = model.folderAccount(for: root)
            let own = model.settings.folderAccounts[(root as NSString).standardizingPath] != nil
            Menu {
                Button { model.setFolderAccount(root, nil) } label: {
                    Label(L("Sin cuenta fija"), systemImage: own || current != nil ? "circle" : "checkmark")
                }
                Divider()
                ForEach(saved) { account in
                    Button { model.setFolderAccount(root, account) } label: {
                        Label(account.alias ?? account.email, systemImage: current?.vaultID == account.vaultID ? "checkmark" : "person")
                    }
                }
            } label: {
                Label(current.map { $0.alias ?? $0.email } ?? L("Cuenta"), systemImage: "person.crop.circle")
            }
            .fixedSize()
            .help(current == nil ? L("Elige la cuenta de Claude Code para este proyecto")
                  : own ? L("Claude Code se abre aquí con esta cuenta") : L("Cuenta heredada de una carpeta superior"))
        }
    }
}
