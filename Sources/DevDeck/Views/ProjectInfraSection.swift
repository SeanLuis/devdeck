import DevDeckCore
import SwiftUI

extension AppModel {
    /// Reads the project's `devdeck.json`, if it has one.
    func loadManifest(root: String) {
        if demo {
            projectManifests[root] = root.hasSuffix("storefront") ? ProjectManifest(services: [
                ManifestService(name: "web", command: "pnpm dev --filter web", port: 3000, health: "/api/health"),
                ManifestService(name: "api", command: "tsx watch src/server.ts", dir: "apps/api", port: 4000, health: "/healthz"),
                ManifestService(name: "worker", command: "pnpm worker", dir: "apps/worker"),
            ], compose: "docker-compose.yml") : nil
            projectHealth[root] = ["web": .healthy, "api": .failing("HTTP 503"), "worker": .down]
            return
        }
        do {
            projectManifests[root] = try ProjectManifest.load(root: root)
            manifestErrors[root] = nil
        } catch {
            projectManifests[root] = nil
            manifestErrors[root] = L("devdeck.json no se pudo leer: %@", error.localizedDescription)
        }
    }

    func refreshHealth(root: String) async {
        guard !demo, let manifest = projectManifests[root] else { return }
        let services = snapshot.groups.first { $0.projectRoot == root }?.services ?? []
        let ports = Set(snapshot.ports.map(\.port))
        let health = await ProjectHealth.check(manifest, root: root, services: services, boundPorts: ports)
        if projectHealth[root] != health { projectHealth[root] = health }
    }

    /// Writes a `devdeck.json` from the commands DevDeck remembers for the project. An existing file is never replaced.
    func writeManifest(root: String) {
        guard !FileManager.default.fileExists(atPath: ProjectManifest.path(root: root)) else { return }
        let manifest = ProjectManifest.from(recipes: recipes[root] ?? [], root: root, composeFile: ProjectStart.composeFile(in: root))
        do {
            try manifest.save(root: root)
            loadManifest(root: root)
            show(L("devdeck.json creado en %@. Revísalo y súbelo al repositorio para compartirlo.", (root as NSString).lastPathComponent))
        } catch {
            show(error.localizedDescription)
        }
    }

    /// Stops the project's services (their commands are kept) and its containers (kept too: stopped, not removed).
    func stopProject(root: String) async {
        if let group = snapshot.group(forProject: root) {
            for service in group.services { await stop(service: service, in: group) }
        }
        let file = projectManifests[root]?.composeFile(root: root) ?? ProjectStart.composeFile(in: root)
        if let file, let docker = dockerPath, snapshot.containers.contains(where: { $0.workingDir == root && $0.isRunning }) {
            show(L("Parando los contenedores…"))
            let result = await Shell.run(docker, ["compose", "-f", file, "stop"], cwd: root, env: loginEnv, timeout: 120)
            if !result.ok { show("docker compose: " + String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(140))) }
            await refreshDocker()
        }
        await refreshHealth(root: root)
    }
}

/// The project's declared infrastructure: each service of its `devdeck.json`, whether it runs and answers,
/// and one button to bring everything up or down.
struct ProjectInfraSection: View {
    @Environment(AppModel.self) private var model
    let root: String

    var body: some View {
        let manifest = model.projectManifests[root]
        VStack(alignment: .leading, spacing: 0) {
            if let manifest {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        header(manifest)
                        ForEach(manifest.services) { service in row(service, manifest) }
                        if let compose = manifest.composeFile(root: root) { composeRow(compose) }
                    }
                    .padding(6)
                }
            } else if let error = model.manifestErrors[root] {
                Text(error).font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .task(id: root) {
            model.loadManifest(root: root)
            while !Task.isCancelled {
                await model.refreshHealth(root: root)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    private func header(_ manifest: ProjectManifest) -> some View {
        let health = model.projectHealth[root] ?? [:]
        let up = manifest.services.filter { health[$0.name]?.isUp ?? false }.count
        let plan = model.startPlan(root: root)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("Infraestructura")).font(.headline)
            Text(ProjectManifest.fileName).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
            Text(L("%d de %d arriba", up, manifest.services.count)).font(.system(size: 12).monospacedDigit())
                .foregroundStyle(up == manifest.services.count ? Theme.success : Theme.secondaryText)
            Spacer()
            if model.startingProjects.contains(root) { ProgressView().controlSize(.small) }
            Button { model.reveal(ProjectManifest.path(root: root)) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Mostrar devdeck.json en Finder"))
            Button { model.loadManifest(root: root); Task { await model.refreshHealth(root: root) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Volver a leer devdeck.json"))
            if up > 0 {
                KillButton(title: L("¿Bajar todo %@?", (root as NSString).lastPathComponent),
                           message: L("Se detienen sus servicios y se paran sus contenedores. Nada se borra: se puede volver a levantar."), label: L("Bajar todo")) {
                    await model.stopProject(root: root)
                }
            }
            if !plan.isEmpty {
                Button { Task { await model.startProject(root: root); await model.refreshHealth(root: root) } } label: { Label(L("Levantar todo"), systemImage: "play.circle.fill") }
                    .buttonStyle(.borderedProminent).disabled(model.startingProjects.contains(root))
            }
        }
    }

    private func row(_ service: ManifestService, _ manifest: ProjectManifest) -> some View {
        let health = model.projectHealth[root]?[service.name]
        return HStack(spacing: 10) {
            Circle().fill(color(health)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(service.name).font(.system(size: 13, weight: .medium))
                    if let port = service.port { Text(":\(port)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.link) }
                    Text(label(health)).font(.system(size: 11)).foregroundStyle(color(health))
                }
                Text(service.command + (service.dir.map { "  ·  " + $0 } ?? "")).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let port = service.port, health?.isUp == true {
                Button { model.openInBrowser(port: port) } label: { Image(systemName: "safari") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Abrir %@", "http://localhost:\(port)"))
            }
            if health == .down {
                Button { model.launch(manifest.recipe(for: service, root: root)) } label: { Label(L("Arrancar"), systemImage: "play.fill") }
                    .controlSize(.small)
            }
        }
    }

    private func composeRow(_ file: String) -> some View {
        let mine = model.snapshot.containers.filter { $0.workingDir == root }
        let running = mine.filter(\.isRunning).count
        return HStack(spacing: 10) {
            Circle().fill(mine.isEmpty || running == 0 ? Theme.ink(0.2) : running == mine.count ? Theme.success : Theme.warning).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(L("Contenedores")).font(.system(size: 13, weight: .medium))
                    Text(mine.isEmpty ? L("parados") : L("%d de %d corriendo", running, mine.count)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
                Text("docker compose -f " + (file as NSString).lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
    }

    private func color(_ health: ServiceHealth?) -> Color {
        switch health {
        case .healthy: Theme.success
        case .running: Theme.link
        case .failing: Theme.danger
        case .down, nil: Theme.ink(0.2)
        }
    }

    private func label(_ health: ServiceHealth?) -> String {
        switch health {
        case .healthy: L("responde")
        case .running: L("corriendo")
        case .failing(let why): L("no responde (%@)", why)
        case .down: L("parado")
        case nil: ""
        }
    }
}
