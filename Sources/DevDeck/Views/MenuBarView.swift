import DevDeckCore
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.system
        HStack(spacing: 3) {
            Image(systemName: model.gameMode ? "gamecontroller.fill"
                  : model.swapReport.thrashing || s.pressure >= 4 ? "exclamationmark.triangle.fill"
                  : s.pressure >= 2 ? "memorychip.fill" : "memorychip")
            // One image and one text: the menu bar draws nothing more from a label. After the memory figure,
            // the agent account in use and how far its 5-hour window has gone, always in sight.
            Text(title(s)).monospacedDigit()
        }
    }
}

extension MenuBarLabel {
    func title(_ s: SystemSample) -> String {
        let memory = model.hasSample ? "\(Int(s.memPercent))%" : "—"
        guard let window = model.activeAccountWindow else { return memory }
        return memory + "  ✦ \(Int(window.percent.rounded()))%"
    }
}

/// The top-bar popover: rings, what's eating memory, dev servers and quick actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.system
        VStack(alignment: .leading, spacing: 14) {
            header(s)
            HStack(spacing: 0) {
                ring("RAM", s.memPercent / 100, "\(Int(s.memPercent))%", "\(String(format: "%.1f", Fmt.gb(s.memUsed))) GB",
                     [Theme.link, Theme.tint, Theme.tint])
                ring("CPU", s.cpuPercent / 100, "\(Int(s.cpuPercent))%", L("%@ núcleos", "\(ProcessInfo.processInfo.activeProcessorCount)"),
                     [Theme.success, Theme.warning, Theme.danger])
                ring("Swap", s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0, shortGB(s.swapUsed), swapState,
                     [Theme.tint, Theme.tint, Theme.tint])
                ring(L("Disco"), s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0, shortGB(s.diskFree), L("libres"),
                     [Theme.tint, Theme.tint])
            }
            .padding(.vertical, 12)
            .glass(cornerRadius: 16)

            if let insight = model.swapReport.insights.first(where: { $0.severity != .info }) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: insight.symbol).foregroundStyle(Color.severity(insight.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.system(.caption).weight(.semibold))
                        Text(insight.detail).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(2)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.severity(insight.severity).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { open(.memory) }
            }

            MenuBarAccounts()

            section(L("Qué consume más"))
            VStack(spacing: 8) {
                let total = Double(max(s.memTotal, 1))
                ForEach(model.snapshot.groups.prefix(4)) { group in
                    HStack(spacing: 10) {
                        GroupIcon(group: group, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(group.name).font(.system(.callout)).lineLimit(1)
                                Spacer()
                                Text(Fmt.bytes(group.memoryBytes)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                            }
                            UsageBar(fraction: Double(group.memoryBytes) / total, tint: Color.kind(group.kind))
                        }
                        if group.killable {
                            KillButton(title: L("¿Cerrar %@?", group.name), message: L("%@ procesos.", "\(group.processCount)"), compact: true) {
                                await model.kill(group: group)
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Color.clear.frame(width: 16, height: 16)
                        }
                    }
                }
            }

            let ports = Array(Set(model.devPorts.map(\.port))).sorted()
            if !ports.isEmpty {
                section(L("Servidores de desarrollo"))
                VStack(spacing: 6) {
                    ForEach(ports.prefix(4), id: \.self) { port in
                        if let binding = model.devPorts.first(where: { $0.port == port }) {
                            HStack(spacing: 10) {
                                Text(verbatim: ":\(port)")
                                    .font(.system(.callout).weight(.bold).monospacedDigit())
                                    .frame(width: 62, alignment: .leading)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(binding.groupName).font(.system(.caption)).lineLimit(1)
                                    Text(binding.container ?? binding.framework ?? binding.processName).font(.caption2).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                                }
                                Spacer()
                                PortActions(binding: binding).font(.system(size: 12))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glass(cornerRadius: 10)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button { PaletteController.shared.show() } label: {
                    Label(L("Copiloto"), systemImage: "sparkle.magnifyingglass").fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .help(L("%@ desde cualquier app", model.settings.hotKeyLabel))
                Spacer()
                Button(L("Abrir panel")) { open(.overview) }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("o")
                Menu {
                    Button(model.gameMode ? L("Salir del modo juego") : L("Activar modo juego")) {
                        if model.gameMode { model.exitGameMode() } else { model.enterGameMode() }
                    }
                    Divider()
                    Button(L("Memoria y swap")) { open(.memory) }
                    Button(L("Ajustes")) { open(.settings) }
                    Divider()
                    Button(L("Salir de DevDeck")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
            }
        }
        .padding(16)
        .frame(width: 384)
        .foregroundStyle(.primary)
        .background(Theme.background)
    }

    private func header(_ s: SystemSample) -> some View {
        HStack(spacing: 10) {
            AppGlyph(size: 26, game: model.gameMode)
            Text(model.gameMode ? L("Modo juego") : "DevDeck").font(.system(size: 14, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.pressure(s.pressure)).frame(width: 7, height: 7).shadow(color: .pressure(s.pressure), radius: 4)
                Text(L("Presión %@", L(s.pressureLabel))).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.ink(0.10), in: Capsule())
        }
    }

    private func ring(_ title: String, _ value: Double, _ text: String, _ subtitle: String, _ colors: [Color]) -> some View {
        VStack(spacing: 6) {
            RingGauge(value: value, lineWidth: 5, semantic: title != "Swap") {
                Text(text).font(.system(size: 12, weight: .bold).monospacedDigit()).minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 8)
            }
            .frame(width: 62, height: 62)
            Text(title).font(.system(.caption).weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(Theme.tertiaryText).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
    }

    private func shortGB(_ bytes: UInt64) -> String {
        let gb = Fmt.gb(bytes)
        return gb >= 10 ? "\(Int(gb.rounded()))G" : String(format: "%.1fG", gb)
    }

    private var swapState: String {
        let r = model.swapReport
        if r.thrashing { return "thrashing" }
        if r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 { return L("activo") }
        return model.system.swapUsed > 1 << 30 ? L("dormido") : L("tranquilo")
    }

    private func open(_ section: SidebarSection) {
        model.selectedSection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The Claude Code accounts in the top-bar popover: the one in use with its limits, and the rest one click away.
struct MenuBarAccounts: View {
    @Environment(AppModel.self) private var model
    @State private var asking: String?

    var body: some View {
        let accounts = model.accounts.accounts(of: "Claude Code")
        if accounts.contains(where: { !$0.windows.isEmpty }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Cuenta del agente").uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                VStack(spacing: 7) {
                    ForEach(accounts) { account in row(account) }
                }
                .padding(10)
                .glass(cornerRadius: 12)
            }
        }
    }

    @ViewBuilder private func row(_ account: AgentAccount) -> some View {
        let short = account.windows.first { $0.name == "5 h" }
        let week = account.windows.first { $0.name == "7 días" }
        HStack(spacing: 8) {
            Circle().fill(account.active ? Theme.success : Theme.ink(0.18)).frame(width: 6, height: 6)
            Text(account.alias ?? account.email).font(.system(size: 12, weight: account.active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if asking == account.id {
                Button(L("Cambiar")) { asking = nil; Task { await model.switchClaudeAccount(account) } }.buttonStyle(.borderedProminent).controlSize(.small)
                Button(L("No")) { asking = nil }.buttonStyle(.bordered).controlSize(.small)
            } else {
                if let short { figure("5 h", short.percent) }
                if let week { figure(L("7 días"), week.percent) }
                if model.switchingAccount == account.id {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else if !account.active, account.number != nil, account.vaultID != nil || model.accounts.switcherPath != nil {
                    Button(L("Usar")) { asking = account.id }.buttonStyle(.bordered).controlSize(.small).frame(width: 44)
                        .disabled(model.switchingAccount != nil)
                } else {
                    Color.clear.frame(width: 44, height: 1)
                }
            }
        }
    }

    private func figure(_ name: String, _ percent: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(Int(percent.rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.level(percent / 100) == Theme.tint ? Color.primary : Theme.level(percent / 100))
            Text(name).font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(width: 34, alignment: .trailing)
    }
}
