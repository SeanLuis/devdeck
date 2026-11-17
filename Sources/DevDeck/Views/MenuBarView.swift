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
        let config = model.settings.menuBar
        var parts: [String] = []
        if config.labelMemory { parts.append(model.hasSample ? "\(Int(s.memPercent))%" : "—") }
        if config.labelAccount, let account = model.menuBarAccountTitle { parts.append(account) }
        return parts.joined(separator: "  ")
    }
}

/// The top-bar popover: rings, what's eating memory, dev servers and quick actions.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = model.system
        VStack(alignment: .leading, spacing: 14) {
            let config = model.settings.menuBar
            header(s)
            if config.system {
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
            }

            if config.insight, let insight = model.swapReport.insights.first(where: { $0.severity != .info }) {
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

            if config.account { MenuBarAccounts() }

            if config.consumers {
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

            }

            let ports = Array(Set(model.devPorts.map(\.port))).sorted()
            if config.servers, !ports.isEmpty {
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
                    Button(L("Personalizar este panel…")) {
                        UserDefaults.standard.set(SettingsPane.menuBar.rawValue, forKey: "settingsPane")
                        open(.settings)
                    }
                    Divider()
                    Button(L("Salir de DevDeck")) { AppPresence.quit() }
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
        AppPresence.showApp()
        openWindow(id: "main")
    }
}

/// The agent accounts in use, one card per agent, with a selector to change to another saved account.
struct MenuBarAccounts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = ["Claude Code", "Codex"].filter { agent in model.accounts.accounts(of: agent).contains(where: \.active) }
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(L("Cuenta del agente").uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    if let read = model.activeClaudeAccount?.usageFetched {
                        Text(L("leído %@", relative(read))).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                    }
                    Button { Task { await model.refreshAccounts(force: true) } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).help(L("Actualizar"))
                }
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(agents, id: \.self) { agent in card(agent) }
                }
                .padding(12)
                .glass(cornerRadius: 12)
            }
        }
    }

    @ViewBuilder private func card(_ agent: String) -> some View {
        let all = model.accounts.accounts(of: agent)
        if let active = all.first(where: \.active) {
            // Accounts DevDeck can switch to: its own saved ones, or the ones claude-swap manages.
            let others = all.filter { !$0.active && ($0.vaultID != nil || ($0.number != nil && model.accounts.switcherPath != nil)) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AgentIcon(name: agent, size: 18)
                    Text(active.alias ?? active.email).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    if model.switchingAccount != nil {
                        ProgressView().controlSize(.small)
                    } else if !others.isEmpty {
                        Menu {
                            ForEach(others) { account in
                                Button { Task { await model.switchClaudeAccount(account) } } label: {
                                    Text((account.alias ?? account.email) + "  ·  " + room(account))
                                }
                            }
                        } label: {
                            Text(L("Cambiar")).font(.system(size: 11, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help(L("Cambiar %@ a otra cuenta guardada", agent))
                    }
                }
                ForEach(["5 h", "7 días"], id: \.self) { name in
                    if let window = active.windows.first(where: { $0.name == name }) { bar(window) }
                }
                if active.windows.isEmpty, let note = active.note {
                    Text(L(note)).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    /// "5 h 12% · 7 días 40%" for an account in the selector.
    private func room(_ account: AgentAccount) -> String {
        let parts = ["5 h", "7 días"].compactMap { name in
            account.percentNow(name).map { L(name) + " " + "\(Int($0.rounded()))%" }
        }
        return parts.isEmpty ? L("sin lectura") : parts.joined(separator: " · ")
    }

    private func bar(_ window: UsageWindow) -> some View {
        let expired = (window.resetsAt ?? .distantFuture) <= Date()
        let percent = expired ? 0 : window.percent
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(L(window.name)).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiaryText)
                Spacer()
                if let resets = window.resetsAt, !expired {
                    Text(L("reinicia %@", relative(resets))).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                }
                Text(expired ? "—" : "\(Int(percent.rounded()))%").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.level(percent / 100) == Theme.tint ? Color.primary : Theme.level(percent / 100))
            }
            UsageBar(fraction: percent / 100, tint: Theme.level(percent / 100))
        }
    }
}
