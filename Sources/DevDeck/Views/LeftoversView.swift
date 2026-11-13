import DevDeckCore
import SwiftUI

/// What agents left running after they were gone. Only shown when there is something.
struct LeftoversPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.agentLeftovers()
        if !items.isEmpty {
            Panel(L("Restos de agentes")) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L("Procesos que un agente arrancó y dejó abiertos al terminar. Ya nadie los controla: revisa cuáles sigues usando."))
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 12)
                        if items.count > 1 {
                            KillButton(title: L("¿Cerrar los %d restos?", items.count),
                                       message: L("%@ en total. Se cierran también los servidores que estén escuchando.", Fmt.bytes(items.reduce(0) { $0 + $1.memoryBytes })),
                                       label: L("Cerrar todos")) {
                                await model.close(leftovers: items)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.bottom, 12)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Theme.ink(0.05)).padding(.vertical, 9) }
                        LeftoverRow(item: item)
                    }
                }
            }
        }
    }
}

struct LeftoverRow: View {
    @Environment(AppModel.self) private var model
    let item: AgentLeftover

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(symbol: symbol, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.command).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    ForEach(item.ports.prefix(3), id: \.self) { Pill(text: ":\($0)", color: Theme.warning) }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metric("RAM", Fmt.bytes(item.memoryBytes))
            metric("CPU", Fmt.percent(item.cpuPercent))
            KillButton(title: L("¿Cerrar %@?", item.command),
                       message: item.ports.isEmpty ? L("%@ procesos, %@.", "\(item.pids.count)", Fmt.bytes(item.memoryBytes))
                           : L("Escucha en el puerto %@: si algo lo usa, dejará de responder.", item.ports.map(String.init).joined(separator: ", ")),
                       compact: true) {
                await model.close(leftovers: [item])
            }
            .buttonStyle(.borderless)
            .frame(width: 30, alignment: .trailing)
        }
    }

    private var symbol: String {
        switch item.kind {
        case .toolServer: return "puzzlepiece.extension"
        case .headlessBrowser: return "rectangle.stack.badge.play"
        case .command: return "terminal"
        }
    }

    private var caption: String {
        var parts: [String] = []
        switch item.kind {
        case .toolServer: parts.append(L("servidor de herramientas sin agente"))
        case .headlessBrowser: parts.append(L("navegador sin ventana huérfano"))
        case .command: parts.append(L("comando lanzado por un agente"))
        }
        parts.append(L("abierto hace %@", Fmt.duration(since: item.since)))
        if item.pids.count > 1 { parts.append(L("%d procesos", item.pids.count)) }
        if let cwd = item.cwd, cwd != "/" { parts.append(Fmt.tilde(cwd)) }
        return parts.joined(separator: " · ")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 12).monospacedDigit())
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(width: 62, alignment: .trailing)
    }
}
