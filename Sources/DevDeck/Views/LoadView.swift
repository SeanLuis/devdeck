import DevDeckCore
import SwiftUI

struct LoadView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var sortByCPU = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HeroHeader(section: .load, title: L("Carga por origen"), subtitle: L("Cada proceso atribuido a quien lo lanzó: proyecto, agente de IA, navegador, Docker o app")) {
                    Picker(L("Ordenar"), selection: $sortByCPU) {
                        Text(L("Por RAM")).tag(false)
                        Text(L("Por CPU")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
                ForEach(GroupKind.allCases, id: \.self) { kind in
                    let groups = sorted(model.snapshot.groups.filter { $0.kind == kind })
                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(kind.title).font(.title3.weight(.semibold))
                                Text(Fmt.bytes(groups.reduce(0) { $0 + $1.memoryBytes })).foregroundStyle(Theme.secondaryText).monospacedDigit()
                            }
                            let limit = shown[kind] ?? 8
                            ForEach(groups.prefix(limit)) { group in
                                GroupRow(group: group, isExpanded: binding(for: group.id))
                            }
                            if groups.count > limit {
                                Button(L("Mostrar más (%@)", "\(groups.count - limit)")) { shown[kind] = limit + 15 }.buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    @State private var shown: [GroupKind: Int] = [:]

    private func sorted(_ groups: [ProcessGroup]) -> [ProcessGroup] {
        sortByCPU ? groups.sorted { $0.cpuPercent > $1.cpuPercent } : groups
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: ProcessGroup
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 12)
                GroupIcon(group: group, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.name).font(.callout.weight(.semibold))
                        if !group.ports.isEmpty {
                            Pill(text: Set(group.ports.map(\.port)).sorted().prefix(4).map { ":\($0)" }.joined(separator: " "), color: .blue)
                        }
                        if !group.origins.isEmpty {
                            Pill(text: L("lanzados por %@", group.origins.sorted { $0.value > $1.value }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")), color: .orange)
                        }
                    }
                    Text(group.detail).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(group.pids.isEmpty ? L("%@ contenedores", "\(group.containers.filter(\.isRunning).count)") : L("%@ procs", "\(group.processCount)"))
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                Text(Fmt.percent(group.cpuPercent)).font(.callout.monospacedDigit()).frame(width: 56, alignment: .trailing)
                Text(Fmt.bytes(group.pids.isEmpty ? group.containerMemory : group.memoryBytes))
                    .font(.callout.monospacedDigit().weight(.medium)).frame(width: 84, alignment: .trailing)
                    .help(group.pids.isEmpty ? L("Memoria dentro de la VM de Docker") : "")
                if group.killable {
                    KillButton(title: L("¿Cerrar %@?", group.name), message: L("Se terminarán %@ procesos (primero de forma ordenada).", "\(group.processCount)"), compact: true) {
                        await model.kill(group: group)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }

            if isExpanded {
                Divider()
                ProcessTable(group: group)
                    .padding(10)
            }
        }
        .glass(cornerRadius: 14)
    }
}

/// The processes of a group, readable: helpers that do the same job are folded into one line ("Pestaña o ventana × 38"),
/// each one says what it is for, and long lists come in pages.
struct ProcessTable: View {
    @Environment(AppModel.self) private var model
    let group: ProcessGroup
    @State private var openRoles: Set<String> = []
    @State private var shown: [String: Int] = [:]

    private struct Bucket: Identifiable {
        let id: String
        let role: ProcessRole?
        var processes: [ProcessRecord]
        var memory: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
        var cpu: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    }

    private static let page = 12

    var body: some View {
        let buckets = self.buckets()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(buckets) { bucket in
                if bucket.processes.count == 1, let process = bucket.processes.first {
                    row(process, role: bucket.role)
                } else {
                    folded(bucket)
                }
            }
        }
    }

    private func buckets() -> [Bucket] {
        let processes = group.pids.compactMap { model.snapshot.processes[$0] }
        let parents = Set(processes.map(\.pid))
        var byKey: [String: Bucket] = [:]
        for process in processes {
            var role = ProcessRole.of(name: process.name, executablePath: process.executablePath, args: process.args)
            // The process the others hang from is the app itself.
            if role == nil, group.kind != .project, !parents.contains(process.ppid), processes.count > 3 {
                role = ProcessRole(key: "main", title: "Aplicación principal", detail: "La ventana y el control de todo lo demás")
            }
            let key = role?.key ?? "pid-\(process.pid)"
            byKey[key, default: Bucket(id: key, role: role, processes: [])].processes.append(process)
        }
        return byKey.values.map { bucket in
            var sorted = bucket
            sorted.processes.sort { $0.memoryBytes > $1.memoryBytes }
            return sorted
        }.sorted { $0.memory > $1.memory }
    }

    private func folded(_ bucket: Bucket) -> some View {
        let open = openRoles.contains(bucket.id)
        let limit = shown[bucket.id] ?? Self.page
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { if open { openRoles.remove(bucket.id) } else { openRoles.insert(bucket.id) } }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.tertiaryText).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Text(L(bucket.role?.title ?? "")).font(.caption.weight(.medium))
                            Text("× \(bucket.processes.count)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        }
                        Text(L(bucket.role?.detail ?? "")).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer()
                    Text(Fmt.percent(bucket.cpu)).font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
                    Text(Fmt.bytes(bucket.memory)).font(.caption.monospacedDigit().weight(.medium)).frame(width: 76, alignment: .trailing)
                    Color.clear.frame(width: 16, height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(bucket.processes.prefix(limit)) { row($0, role: nil) }
                    if bucket.processes.count > limit {
                        Button(L("Mostrar %@ más (quedan %@)", "\(min(Self.page * 2, bucket.processes.count - limit))", "\(bucket.processes.count - limit)")) {
                            shown[bucket.id] = limit + Self.page * 2
                        }
                        .buttonStyle(.borderless).font(.caption).padding(.leading, 62)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.ink(0.08)).frame(width: 1).padding(.leading, 4) }
            }
        }
    }

    private func row(_ p: ProcessRecord, role: ProcessRole?) -> some View {
        HStack(spacing: 10) {
            Text(String(p.pid)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(role.map { L($0.title) } ?? p.name).font(.caption.weight(.medium))
                    if role != nil { Text(p.name).font(.caption2).foregroundStyle(Theme.tertiaryText).lineLimit(1) }
                }
                Text(role.map { L($0.detail) } ?? Self.shortCommand(p))
                    .font(role == nil ? .caption2.monospaced() : .caption2).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    .help(AISnapshotBuilder.redact(String(p.commandLine.prefix(600))))
            }
            Spacer()
            Text(Fmt.duration(since: p.startTime)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.tertiaryText).frame(width: 60, alignment: .trailing)
            Text(Fmt.percent(p.cpuPercent)).font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
            Text(Fmt.bytes(p.memoryBytes)).font(.caption.monospacedDigit()).frame(width: 76, alignment: .trailing)
            if p.isMine && group.killable {
                if model.busyPids.contains(p.pid) {
                    ProgressView().controlSize(.mini)
                } else {
                    KillButton(title: L("¿Matar %@ (PID %@)?", p.name, "\(p.pid)"), message: AISnapshotBuilder.redact(String(p.commandLine.prefix(200))), label: L("Matar"), compact: true) {
                        await model.kill(pid: p.pid)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
        }
    }

    /// The command without the noise: no full path to the binary, no flags that are only identifiers.
    static func shortCommand(_ p: ProcessRecord) -> String {
        let args = p.args.isEmpty ? [p.name] : p.args
        let kept = args.enumerated().compactMap { index, arg -> String? in
            if index == 0 { return (arg as NSString).lastPathComponent }
            if arg.hasPrefix("--") && arg.count > 60 { return nil }
            return arg.hasPrefix("/") && arg.count > 40 ? "…/" + (arg as NSString).lastPathComponent : arg
        }
        return AISnapshotBuilder.redact(String(kept.joined(separator: " ").prefix(180)))
    }
}
