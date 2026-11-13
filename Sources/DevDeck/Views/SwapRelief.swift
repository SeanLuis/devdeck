import AppKit
import DevDeckCore
import SwiftUI

/// One way to get swap back: macOS only returns it when whoever holds it quits or starts again.
struct SwapReliefOption: Identifiable {
    enum Action { case close, restartServices, relaunch }

    var id: String { group.id }
    let group: ProcessGroup
    let action: Action
    /// Memory of the group that is compressed or in swap right now.
    var recover: UInt64 { group.offloadedBytes }

    var actionTitle: String {
        switch action {
        case .close: return L("Cerrar")
        case .restartServices: return L("Reiniciar servidores")
        case .relaunch: return L("Cerrar y volver a abrir")
        }
    }

    var note: String {
        switch action {
        case .close:
            return group.kind == .headless ? L("Nadie los está mirando; los agentes abren otros cuando los necesitan") : L("Se cierra; lo abres tú cuando lo necesites")
        case .restartServices: return L("Mismo comando, carpeta y entorno; vuelve en unos segundos")
        case .relaunch: return L("La app se abre de nuevo; los navegadores recuperan sus pestañas")
        }
    }
}

@MainActor
extension AppModel {
    /// Who holds memory out of RAM, with the gentlest action that gets it back. Biggest first.
    func swapReliefOptions() -> [SwapReliefOption] {
        snapshot.groups
            .filter { $0.killable && $0.offloadedBytes > 96 << 20 && $0.kind != .agent }
            .sorted { $0.offloadedBytes > $1.offloadedBytes }
            .prefix(8)
            .map { group in
                let action: SwapReliefOption.Action
                switch group.kind {
                case .project where !group.services.isEmpty: action = .restartServices
                case .app, .browser: action = runningApp(of: group) != nil ? .relaunch : .close
                default: action = .close
                }
                return SwapReliefOption(group: group, action: action)
            }
    }

    private func runningApp(of group: ProcessGroup) -> NSRunningApplication? {
        let pids = Set(group.pids)
        return NSWorkspace.shared.runningApplications.first { pids.contains($0.processIdentifier) && $0.bundleURL != nil && $0.activationPolicy == .regular }
    }

    /// Applies what the user ticked, one by one, and reports how much swap came back.
    func applySwapRelief(_ options: [SwapReliefOption]) async {
        guard !options.isEmpty, !swapRelieving else { return }
        swapRelieving = true
        defer { swapRelieving = false }
        let before = system.swapUsed
        for option in options {
            guard let group = snapshot.group(option.group.id) else { continue }
            switch option.action {
            case .close:
                await kill(group: group)
            case .restartServices:
                for service in group.services { await restart(service: service, in: group) }
            case .relaunch:
                guard let app = runningApp(of: group), let url = app.bundleURL else { await kill(group: group); continue }
                show(L("Reabriendo %@…", group.name))
                app.terminate()
                for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(nanoseconds: 250_000_000) }
                if !app.isTerminated { show(L("%@ no se cerró (¿tiene algo sin guardar?); no lo fuerzo", group.name)); continue }
                try? await Task.sleep(nanoseconds: 800_000_000)
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        // Give the kernel a moment to drop the pages, then measure.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let after = system.swapUsed
        let freed = before > after ? before - after : 0
        let message = freed > 32 << 20 ? L("Swap liberado: %@ (ahora %@)", Fmt.bytes(freed), Fmt.bytes(after))
                                       : L("Hecho. El swap sigue en %@: macOS lo irá soltando conforme reutilice la memoria", Fmt.bytes(after))
        show(message)
        pushAlert(AlertEvent(title: L("Liberar swap"), message: message, severity: .info))
    }
}

/// Pick what to close or restart to get swap back. Nothing happens until "Liberar".
struct SwapReliefSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var options: [SwapReliefOption] = []
    @State private var selected: Set<String> = []

    var body: some View {
        let total = options.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.recover }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Liberar swap")).font(.system(size: 16, weight: .semibold))
                Text(L("macOS solo devuelve el swap cuando quien lo ocupa se cierra o arranca de nuevo. Marca lo que quieras; nada se toca hasta que pulses Liberar."))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            if options.isEmpty {
                EmptyHint(title: L("Nada relevante fuera de RAM"), symbol: "checkmark.seal", message: L("Ningún origen tiene memoria suficiente en swap como para que merezca la pena."))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        if index > 0 { Divider().overlay(Theme.ink(0.05)) }
                        Toggle(isOn: Binding(get: { selected.contains(option.id) },
                                             set: { if $0 { selected.insert(option.id) } else { selected.remove(option.id) } })) {
                            HStack(spacing: 10) {
                                GroupIcon(group: option.group, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(option.group.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                        Pill(text: option.actionTitle)
                                    }
                                    Text(option.note).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("≈ \(Fmt.bytes(option.recover))").font(.system(size: 13).monospacedDigit())
                                    Text(L("de %@", Fmt.bytes(option.group.memoryBytes))).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .background(Theme.ink(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(L("Las cifras son un estimado de la memoria de cada uno que está comprimida o en swap. Los agentes de IA no se ofrecen aquí para no cortar su trabajo."))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("Cancelar")) { dismiss() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button(total > 0 ? L("Liberar ~%@", Fmt.bytes(total)) : L("Liberar")) {
                    let chosen = options.filter { selected.contains($0.id) }
                    dismiss()
                    Task { await model.applySwapRelief(chosen) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 580)
        .background(Theme.background)
        .appAppearance(model.settings.appearance)
        .onAppear {
            options = model.swapReliefOptions()
            // Only what nobody is using starts ticked.
            selected = Set(options.filter { $0.group.kind == .headless }.map(\.id))
        }
    }
}
