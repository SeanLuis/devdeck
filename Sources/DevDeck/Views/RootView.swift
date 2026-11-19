import DevDeckCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let section = model.selectedSection ?? .overview
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: 220)
                VStack(spacing: 0) {
                    GameModeBanner()
                    detail(for: section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(section)
                }
            }
            ToastOverlay()
        }
        .foregroundStyle(.primary)
        .animation(.snappy, value: model.toast)
        .sheet(isPresented: Binding(get: { model.showUpdate && model.availableUpdate != nil }, set: { model.showUpdate = $0 })) {
            if let update = model.availableUpdate { UpdateSheet(release: update).environment(model) }
        }
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        case .overview: OverviewView()
        case .memory: MemoryView()
        case .history: HistoryView()
        case .ports: PortsView()
        case .projects: ProjectsView()
        case .agents: AgentsView()
        case .load: LoadView()
        case .caches: CachesView()
        case .toolkit: ToolkitView()
        case .rules: RulesView()
        case .copilot: CopilotView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    private let groups: [(String, [SidebarSection])] = [
        (L("Sistema"), [.overview, .memory, .history, .load]),
        (L("Desarrollo"), [.ports, .projects, .agents, .caches, .toolkit]),
        (L("Control"), [.rules, .copilot, .settings]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                AppGlyph(size: 24, game: model.gameMode)
                Text("DevDeck").font(.system(size: 15, weight: .semibold))
                if model.gameMode { Pill(text: L("juego"), color: Theme.success) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 14)

            // The sections scroll when the window is short; the header and the bottom block always keep their room.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { title, sections in
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.tertiaryText)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        ForEach(sections) { section in
                            SidebarRow(section: section, selected: (model.selectedSection ?? .overview) == section, badge: badge(for: section))
                                .onTapGesture { model.selectedSection = section }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
            VStack(spacing: 8) {
                Button { PaletteController.shared.show() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12))
                        Text(L("Buscar")).font(.system(size: 13))
                        Spacer()
                        Keycap(text: model.settings.hotKeyLabel)
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .glass(cornerRadius: 8)
                }
                .buttonStyle(.plain)
                UpdateCard()
                SidebarFooter()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.ink(0.06)).frame(height: 1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.ink(0.06)).frame(width: 1) }
    }

    private func badge(for section: SidebarSection) -> String? {
        switch section {
        case .ports: let n = Set(model.devPorts.map(\.port)).count; return n > 0 ? "\(n)" : nil
        case .projects: let n = model.runningProjectRoots.count; return n > 0 ? "\(n)" : nil
        case .agents:
            let n = model.snapshot.groups.filter { $0.kind == .agent }.count
            return n > 0 ? "\(n)" : nil
        case .memory:
            let r = model.swapReport
            if r.thrashing { return "!" }
            return r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 ? L("activo") : nil
        case .rules:
            let n = model.alerts.filter { $0.severity != .info && Date().timeIntervalSince($0.time) < 3600 }.count
            return n > 0 ? "\(n)" : nil
        default: return nil
        }
    }
}

struct SidebarRow: View {
    let section: SidebarSection
    let selected: Bool
    let badge: String?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(selected ? Color.primary : Theme.secondaryText)
            Text(section.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.primary : Theme.ink(0.78))
                .lineLimit(1)
            Spacer()
            if let badge {
                Text(badge).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink(selected ? 0.09 : hovering ? 0.04 : 0)))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sys = model.system
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color.pressure(sys.pressure)).frame(width: 6, height: 6)
                Text(L("Presión %@", L(sys.pressureLabel))).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
                Spacer()
                Text("Swap \(Fmt.bytes(sys.swapUsed))").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            footerBar("RAM", sys.memPercent / 100)
            footerBar("CPU", sys.cpuPercent / 100)
            let power = model.power
            if power.hasBattery || power.thermalLevel > 0 {
                HStack(spacing: 5) {
                    if let percent = power.batteryPercent {
                        Image(systemName: power.charging ? "battery.100percent.bolt" : percent < 20 ? "battery.25percent" : "battery.75percent")
                            .font(.system(size: 10)).foregroundStyle(!power.onAC && percent < 20 ? Theme.warning : Theme.tertiaryText)
                        Text(batteryText(power, percent)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if power.thermalLevel > 0 {
                        Image(systemName: "thermometer.medium").font(.system(size: 10)).foregroundStyle(power.thermalLevel >= 2 ? Theme.danger : Theme.warning)
                        Text(L(power.thermalLabel)).font(.system(size: 10)).foregroundStyle(power.thermalLevel >= 2 ? Theme.danger : Theme.warning).lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .glass(cornerRadius: 8)
    }

    private func batteryText(_ power: PowerStatus, _ percent: Double) -> String {
        var text = "\(Int(percent.rounded()))%"
        if let minutes = power.minutesLeft { text += " · " + (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min") }
        else if power.charging { text += " · " + L("cargando") }
        return text
    }

    private func footerBar(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.tertiaryText).frame(width: 26, alignment: .leading)
            UsageBar(fraction: value, tint: .usage(value))
            Text(Fmt.percent(value * 100)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 30, alignment: .trailing)
        }
    }
}
