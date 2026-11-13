import DevDeckCore
import SwiftUI

struct PortsView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var devOnly = true
    @State private var sortKey: SortKey = .port

    enum SortKey: String, CaseIterable { case port = "Puerto", memory = "Memoria", cpu = "CPU", project = "Proyecto" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HeroHeader(section: .ports, title: L("Puertos"), subtitle: L("Cada puerto con el proyecto, servidor y contenedor que hay detrás"))
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                        TextField(L("Buscar puerto, proyecto, proceso…"), text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .glass(cornerRadius: 10)
                    .frame(maxWidth: 380)
                    Toggle(L("Solo desarrollo"), isOn: $devOnly).toggleStyle(.switch)
                    Spacer()
                    Picker(L("Ordenar"), selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                let list = rows
                if list.isEmpty {
                    EmptyHint(title: L("Ningún puerto"), symbol: "point.3.connected.trianglepath.dotted", message: L("No hay servidores escuchando con este filtro."))
                        .glass(cornerRadius: 18)
                }
                LazyVStack(spacing: 10) {
                    ForEach(list) { binding in PortRow(binding: binding) }
                }
            }
            .padding(28)
        }
    }

    private var rows: [PortBinding] {
        var list = devOnly ? model.devPorts : model.snapshot.ports
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                String($0.port).contains(q) || $0.groupName.lowercased().contains(q) || $0.processName.lowercased().contains(q)
                    || ($0.framework ?? "").lowercased().contains(q) || ($0.container ?? "").lowercased().contains(q)
            }
        }
        var seen = Set<String>()
        list = list.filter { seen.insert("\($0.port)|\($0.pid)").inserted }
        switch sortKey {
        case .port: return list.sorted { $0.port < $1.port }
        case .memory: return list.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpu: return list.sorted { $0.cpuPercent > $1.cpuPercent }
        case .project: return list.sorted { $0.groupName.localizedCaseInsensitiveCompare($1.groupName) == .orderedAscending }
        }
    }
}

struct PortRow: View {
    @Environment(AppModel.self) private var model
    let binding: PortBinding
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ":\(binding.port)").font(.system(size: 16, weight: .semibold, design: .monospaced))
                Text(binding.isLoopbackOnly ? L("solo local") : L("en la red")).font(.caption2)
                    .foregroundStyle(binding.isLoopbackOnly ? Theme.tertiaryText : Theme.warning)
            }
            .frame(width: 96, alignment: .leading)
            KindIcon(kind: binding.groupKind, size: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(binding.groupName).font(.system(.body).weight(.semibold)).lineLimit(1)
                    if let fw = binding.framework { Pill(text: fw, color: Theme.link) }
                }
                Text(binding.container.map { L("contenedor %@", $0) } ?? binding.projectRoot.map(Fmt.tilde) ?? binding.processName)
                    .font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            metric(Fmt.bytes(binding.memoryBytes), L("memoria"))
            metric(Fmt.percent(binding.cpuPercent), "CPU")
            metric(uptime(binding.startTime), L("activo"))
            metric(String(binding.pid), "PID")
            PortActions(binding: binding)
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glass(cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink(hovering ? 0.25 : 0), lineWidth: 1))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("Abrir en el navegador")) { model.openInBrowser(port: binding.port) }
            Button(L("Copiar URL")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://localhost:\(binding.port)", forType: .string)
            }
            if let root = binding.projectRoot {
                Button(L("Ver proyecto")) { model.selectedProjectRoot = root; model.selectedSection = .projects }
                Button(L("Mostrar en Finder")) { model.reveal(root) }
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(.callout).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(Theme.tertiaryText)
        }
        .frame(width: 76, alignment: .trailing)
    }
}

struct PortActions: View {
    @Environment(AppModel.self) private var model
    let binding: PortBinding

    var body: some View {
        HStack(spacing: 12) {
            Button { model.openInBrowser(port: binding.port) } label: { Image(systemName: "safari") }
                .help(L("Abrir %@", "http://localhost:\(binding.port)"))
            if let root = binding.serviceRootPid, let found = model.snapshot.service(rootPid: root) {
                if model.busyPids.contains(root) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await model.restart(service: found.1, in: found.0) } } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("Reiniciar %@ con el mismo comando y entorno", found.1.label))
                    KillButton(title: L("¿Detener %@?", found.1.label), message: L("Se guardará el comando para volver a arrancarlo."), label: L("Detener"), compact: true) {
                        await model.stop(service: found.1, in: found.0)
                    }
                }
            } else if binding.groupKind != .system, binding.container == nil {
                KillButton(title: L("¿Matar %@ (PID %@)?", binding.processName, "\(binding.pid)"), message: L("Libera el puerto :%@.", "\(binding.port)"), label: L("Matar"), compact: true) {
                    await model.kill(pid: binding.pid)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
    }
}
