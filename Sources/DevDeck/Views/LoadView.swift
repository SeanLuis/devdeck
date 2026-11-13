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
                            ForEach(groups) { group in
                                GroupRow(group: group, isExpanded: binding(for: group.id))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }

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
                KindIcon(kind: group.kind, size: 26)
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

struct ProcessTable: View {
    @Environment(AppModel.self) private var model
    let group: ProcessGroup

    var body: some View {
        let procs = group.pids.compactMap { model.snapshot.processes[$0] }.sorted { $0.memoryBytes > $1.memoryBytes }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(procs.prefix(40)) { p in
                HStack(spacing: 10) {
                    Text(String(p.pid)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.name).font(.caption.weight(.medium))
                        Text(AISnapshotBuilder.redact(p.commandLine)).font(.caption2.monospaced()).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
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
                    }
                }
            }
            if procs.count > 40 {
                Text(L("… y %@ procesos más", "\(procs.count - 40)")).font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}
