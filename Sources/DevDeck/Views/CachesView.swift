import DevDeckCore
import SwiftUI

struct CachesView: View {
    @Environment(AppModel.self) private var model
    @State private var kindFilter: CacheKind?
    @State private var limit = 40

    var body: some View {
        let project = filteredProjectCaches
        let projectTotal = model.allProjectCaches.reduce(0) { $0 + $1.sizeBytes }
        let safeTotal = model.allProjectCaches.filter { $0.safe }.reduce(0) { $0 + $1.sizeBytes }
        let globalTotal = model.globalCaches.reduce(0) { $0 + $1.sizeBytes }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroHeader(section: .caches, title: L("Cachés y disco"), subtitle: L("Builds, dependencias y cachés que se pueden regenerar")) {
                    if let progress = model.cacheScanProgress {
                        HStack { ProgressView().controlSize(.small); Text(progress).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                            .frame(maxWidth: 320)
                    } else {
                        Button { Task { await model.scanCaches() } } label: { Label(L("Volver a medir"), systemImage: "arrow.clockwise") }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    StatCard(title: L("Cachés de proyectos"), value: Fmt.bytes(projectTotal), subtitle: L("%@ carpetas en %@ proyectos", "\(model.allProjectCaches.count)", "\(model.projectCaches.count)"), symbol: "folder")
                    StatCard(title: L("Regenerables sin riesgo"), value: Fmt.bytes(safeTotal), subtitle: ".next, .turbo, target, coverage…", symbol: "checkmark.shield", tint: .green)
                    StatCard(title: L("Cachés globales"), value: Fmt.bytes(globalTotal), subtitle: L("npm, pnpm, uv, Homebrew, Xcode, agentes…"), symbol: "globe")
                    StatCard(title: L("Disco libre"), value: Fmt.bytes(model.system.diskFree), subtitle: model.cacheScanDate.map { L("medido %@", relative($0)) } ?? L("sin medir"),
                             symbol: "internaldrive", tint: model.system.diskFree < 15 << 30 ? .red : .accentColor)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L("Por proyecto")).font(.headline)
                            Spacer()
                            Picker(L("Tipo"), selection: $kindFilter) {
                                Text(L("Todos")).tag(CacheKind?.none)
                                ForEach([CacheKind.buildCache, .dependencies, .buildOutput, .virtualEnv], id: \.self) { Text($0.title).tag(CacheKind?.some($0)) }
                            }
                            .frame(width: 220)
                        }
                        if project.isEmpty {
                            EmptyHint(title: model.cacheScanProgress == nil ? L("Nada que mostrar") : L("Midiendo…"), symbol: "internaldrive",
                                      message: L("Se buscan .next, node_modules, .turbo, target, .venv… en tus carpetas de proyectos."))
                        }
                        ForEach(project.prefix(limit)) { entry in
                            CacheRow(entry: entry)
                            Divider()
                        }
                        if project.count > limit {
                            Button(L("Mostrar más (%@)", "\(project.count - limit)")) { limit += 40 }.buttonStyle(.link)
                        }
                    }
                    .padding(6)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Globales y de herramientas")).font(.headline)
                        ForEach(model.globalCaches) { entry in
                            GlobalCacheRow(entry: entry)
                            Divider()
                        }
                    }
                    .padding(6)
                }
            }
            .padding(28)
        }
    }

    private var filteredProjectCaches: [CacheEntry] {
        let all = model.allProjectCaches.sorted { $0.sizeBytes > $1.sizeBytes }
        guard let kindFilter else { return all }
        return all.filter { $0.kind == kindFilter }
    }
}

struct GlobalCacheRow: View {
    @Environment(AppModel.self) private var model
    let entry: CacheEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind == .agentData ? "sparkles" : "wrench.and.screwdriver")
                .foregroundStyle(entry.safe ? .green : .orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(L(entry.label)).fontWeight(.medium)
                    Pill(text: entry.kind.title, color: entry.safe ? .green : .orange)
                }
                Text("\(L(entry.note)) · \(Fmt.tilde(entry.path))").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Fmt.bytes(entry.sizeBytes)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 80, alignment: .trailing)
            Button { model.reveal(entry.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            KillButton(title: L("¿Limpiar %@?", L(entry.label)), message: L("%@. Regenerar: %@.", L(entry.note), L(entry.regenerate)), label: actionLabel) {
                await model.clean(entry)
            }
        }
    }

    private var actionLabel: String {
        switch entry.method {
        case .command: return L("Limpiar")
        case .deleteFilesOlderThan(let days, _): return L("Borrar > %@ días", "\(days)")
        default: return L("Vaciar")
        }
    }
}
