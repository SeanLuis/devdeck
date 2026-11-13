import Charts
import DevDeckCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var minutes: Double = 10

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeroHeader(section: .overview, title: L("Resumen"), subtitle: L("Qué está consumiendo tu Mac y de dónde viene")) {
                    Button {
                        PaletteController.shared.show()
                    } label: { Label(L("Copiloto"), systemImage: "sparkle.magnifyingglass") }
                        .buttonStyle(.bordered)
                }
                HealthHero()
                Panel(L("Memoria por origen"), symbol: "chart.bar.xaxis") {
                    HStack {
                        Spacer()
                        Picker("", selection: $minutes) {
                            Text("5 min").tag(5.0)
                            Text("10 min").tag(10.0)
                            Text("30 min").tag(30.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    .padding(.top, -34)
                    MemoryByOriginChart(minutes: minutes)
                        .frame(height: 240)
                }
                HStack(alignment: .top, spacing: 18) {
                    Panel(L("Mayores consumidores"), symbol: "flame") { TopConsumersList(limit: 8) }
                    Panel(L("Alertas recientes"), symbol: "bell") { AlertsList(limit: 6) }
                        .frame(maxWidth: 420)
                }
            }
            .padding(28)
        }
    }
}

/// Big CleanMyMac-style status block: a large memory ring plus smaller rings and a one-line verdict.
struct HealthHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.system
        let verdict = verdictText
        HStack(spacing: 34) {
            RingGauge(value: s.memPercent / 100, lineWidth: 8,
                      colors: [Theme.link, Theme.tint, Theme.tint, Theme.danger]) {
                VStack(spacing: 2) {
                    Text("\(Int(s.memPercent))%").font(.system(size: 34, weight: .semibold).monospacedDigit())
                    Text("RAM").font(.system(.caption).weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text(L("%@ de %@ GB", String(format: "%.1f", Fmt.gb(s.memUsed)), "\(Int(Fmt.gb(s.memTotal).rounded()))"))
                        .font(.caption2).foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.pressure(s.pressure)).frame(width: 10, height: 10)
                        Text(verdict.title).font(.system(size: 17, weight: .semibold))
                    }
                    Text(verdict.detail).font(.callout).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 26) {
                    MetricRing(title: "CPU", value: s.cpuPercent / 100, text: Fmt.percent(s.cpuPercent),
                               subtitle: L("%@ núcleos", "\(ProcessInfo.processInfo.activeProcessorCount)"), size: 84)
                    MetricRing(title: "Swap", value: s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0,
                               text: shortGB(s.swapUsed), subtitle: swapState, size: 84)
                    MetricRing(title: L("Disco"), value: s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0,
                               text: shortGB(s.diskFree), subtitle: L("libres"), size: 84)
                    MetricRing(title: "Dev", value: min(1, Double(model.runningProjectRoots.count) / 8),
                               text: "\(model.runningProjectRoots.count)", subtitle: L("%@ puertos", "\(Set(model.devPorts.map(\.port)).count)"), size: 84,
                               colors: [Theme.tint, Theme.tint])
                    MetricRing(title: "Headless", value: min(1, Double(model.snapshot.headlessBrowserCount) / 20),
                               text: "\(model.snapshot.headlessBrowserCount)", subtitle: "Chrome", size: 84)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .glass(cornerRadius: 12)
    }

    private func shortGB(_ bytes: UInt64) -> String {
        let gb = Fmt.gb(bytes)
        return gb >= 10 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
    }

    private var swapState: String {
        let r = model.swapReport
        if r.thrashing { return "thrashing" }
        if r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 { return L("activo") }
        return model.system.swapUsed > 1 << 30 ? L("dormido") : L("en uso")
    }

    private var verdictText: (title: String, detail: String) {
        let s = model.system
        let r = model.swapReport
        if r.thrashing || s.pressure >= 4 {
            return (L("Tu Mac está sufriendo"), L("La memoria no alcanza y está moviendo datos al disco sin parar. Mira “Memoria y swap” para saber qué cerrar."))
        }
        if s.pressure >= 2 || r.swapOutRate > 1_048_576 {
            return (L("Memoria justa"), L("macOS está comprimiendo y mandando memoria a swap. Cerrar lo que no uses evitará tirones."))
        }
        if let top = model.snapshot.groups.first(where: { $0.kind != .system }) {
            return (L("Todo en orden"), L("Lo que más consume ahora es %@ con %@.", top.name, Fmt.bytes(top.memoryBytes)))
        }
        return (L("Todo en orden"), L("Recolectando datos…"))
    }
}

struct MemoryByOriginChart: View {
    @Environment(AppModel.self) private var model
    let minutes: Double

    struct Series: Identifiable {
        let id: String
        let name: String
        let points: [MetricPoint]
    }

    var body: some View {
        let top = model.snapshot.groups.filter { $0.kind != .system }.prefix(7)
        let series = top.map { Series(id: $0.id, name: $0.name, points: model.history(for: $0.id, minutes: minutes)) }
        if series.allSatisfy({ $0.points.count < 2 }) {
            EmptyHint(title: L("Recolectando datos…"), symbol: "chart.xyaxis.line", message: L("El gráfico se llena con cada muestra (cada %@ s).", "\(Int(model.settings.sampleInterval))"))
        } else {
            Chart {
                ForEach(series) { s in
                    ForEach(s.points, id: \.time) { p in
                        AreaMark(x: .value(L("Hora"), p.time), y: .value("GB", p.memMB / 1024), stacking: .standard)
                            .foregroundStyle(by: .value(L("Origen"), s.name))
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartForegroundStyleScale(range: ChartPalette.colors)
            .chartYAxisLabel("GB")
            .chartLegend(position: .bottom, spacing: 10)
        }
    }
}

enum ChartPalette {
    /// One hue, stepped in lightness: series stay distinguishable without turning the chart into confetti.
    static let colors: [Color] = [Color(light: 0x27272A, dark: 0xE4E4E7), Color(light: 0x71717A, dark: 0x9CA3AF), Color(light: 0xA1A1AA, dark: 0x6B7280),
                                  Color(light: 0x52525B, dark: 0xBFC5CE), Color(light: 0xD4D4D8, dark: 0x4B5563), Color(light: 0x8E8E96, dark: 0x7C8696),
                                  Color(light: 0x3F3F46, dark: 0xD1D5DB), Color(light: 0xBDBDC4, dark: 0x374151)]
}

struct TopConsumersList: View {
    @Environment(AppModel.self) private var model
    let limit: Int

    var body: some View {
        let total = Double(max(model.system.memTotal, 1))
        VStack(spacing: 10) {
            ForEach(model.snapshot.groups.prefix(limit)) { group in
                HStack(spacing: 12) {
                    GroupIcon(group: group, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(group.name).font(.system(.callout).weight(.medium)).lineLimit(1)
                            if !group.ports.isEmpty {
                                Pill(text: Set(group.ports.map(\.port)).sorted().prefix(3).map { ":\($0)" }.joined(separator: " "), color: Theme.link)
                            }
                        }
                        UsageBar(fraction: Double(group.memoryBytes) / total, tint: Color.kind(group.kind))
                    }
                    Text(Fmt.bytes(group.memoryBytes)).font(.system(.callout).monospacedDigit()).frame(width: 80, alignment: .trailing)
                    Text(Fmt.percent(group.cpuPercent)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText).frame(width: 46, alignment: .trailing)
                    if group.killable {
                        KillButton(title: L("¿Cerrar %@?", group.name), message: L("Se terminarán %@ procesos.", "\(group.processCount)"), compact: true) {
                            await model.kill(group: group)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Color.clear.frame(width: 16, height: 16)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open(group) }
            }
        }
    }

    private func open(_ group: ProcessGroup) {
        if group.kind == .project, let root = group.projectRoot {
            model.selectedProjectRoot = root
            model.selectedSection = .projects
        } else {
            model.selectedSection = .load
        }
    }
}

struct AlertsList: View {
    @Environment(AppModel.self) private var model
    let limit: Int

    var body: some View {
        if model.alerts.isEmpty {
            EmptyHint(title: L("Sin alertas"), symbol: "checkmark.seal", message: L("Las reglas avisarán aquí y con notificaciones."))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.alerts.prefix(limit)) { alert in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: alert.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.severity(alert.severity))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.title).font(.system(.callout).weight(.medium))
                            Text(alert.message).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2)
                            if let action = alert.actionTaken { Text("→ \(action)").font(.caption).foregroundStyle(Theme.link) }
                        }
                        Spacer()
                        Text(alert.time, style: .relative).font(.caption2).foregroundStyle(Theme.tertiaryText)
                    }
                }
            }
        }
    }
}
