import Charts
import DevDeckCore
import SwiftUI

@MainActor
extension AppModel {
    /// Once a minute: write the minute to disk and keep the recent ones at hand.
    func recordTimeline() {
        guard !headless, !demo, hasSample else { return }
        let point = TimelinePoint.make(snapshot: snapshot, system: system)
        guard point.minute != timeline.last?.minute else { return }
        timeline.append(point)
        if timeline.count > 6 * 60 { timeline.removeFirst(timeline.count - 6 * 60) }
        let store = timelineStore
        Task.detached(priority: .utility) { store.append(point) }
        // Every ten minutes, look for memory that only grows.
        if point.minute % 10 == 0 { checkLeaks() }
    }

    func loadRecentTimeline() {
        let store = timelineStore
        Task { [weak self] in
            let points = await Task.detached(priority: .utility) { store.load(from: Date().addingTimeInterval(-6 * 3600)) }.value
            guard let self else { return }
            self.timeline = points + self.timeline.filter { point in !points.contains { $0.minute == point.minute } }
            self.leaks = TimelineAnalysis.leaks(self.leakWindow())
        }
    }

    private func leakWindow() -> [TimelinePoint] {
        let cutoff = Int(Date().timeIntervalSince1970 / 60) - 180
        return timeline.filter { $0.minute >= cutoff }
    }

    private func checkLeaks() {
        let found = TimelineAnalysis.leaks(leakWindow())
        let known = Set(leaks.map(\.id))
        leaks = found
        // A recommendation, once per leak: restart it, or look at it.
        for leak in found where !known.contains(leak.id) && !announcedLeaks.contains(leak.id) {
            announcedLeaks.insert(leak.id)
            let message = L("%@ pasó de %@ a %@ en %@ y no baja. Suele ser una fuga de memoria.", leak.name, Fmt.bytes(UInt64(leak.fromMB) << 20),
                            Fmt.bytes(UInt64(leak.toMB) << 20), Self.hoursText(leak.hours))
            pushAlert(AlertEvent(title: L("Memoria que solo crece"), message: message, severity: .warning, groupID: leak.id))
            let group = snapshot.group(leak.id)
            let restartable = group.map { $0.kind == .project && !$0.services.isEmpty } ?? false
            presentAlert(title: L("Memoria que solo crece"), body: message, severity: .warning,
                         actionLabel: restartable ? L("Reiniciar %@", leak.name) : L("Ver el historial"), seconds: 25,
                         action: { [weak self] in
                             guard let self else { return }
                             if restartable, let group = self.snapshot.group(leak.id) {
                                 Task { for service in group.services { await self.restart(service: service, in: group) } }
                             } else {
                                 Notifier.shared.onOpen?(.history)
                             }
                         })
        }
    }

    static func hoursText(_ hours: Double) -> String {
        hours >= 1.5 ? L("%@ h", String(format: "%.0f", hours)) : L("%@ min", String(format: "%.0f", hours * 60))
    }
}

/// What happened while nobody was looking: memory and swap over hours or days, who was using it at any minute,
/// the moments it hit the limit, and what only grows.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var hours: Double = 6
    @State private var points: [TimelinePoint] = []
    @State private var selected: Date?
    @State private var loading = false

    var body: some View {
        let drawn = TimelineAnalysis.thin(points)
        let moments = TimelineAnalysis.moments(points)
        let focus = focusPoint
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroHeader(section: .history, title: L("Historial"), subtitle: L("Qué pasó en tu Mac aunque no estuvieras mirando: se guarda un resumen por minuto durante 7 días")) {
                    Picker("", selection: $hours) {
                        Text(L("1 h")).tag(1.0)
                        Text(L("6 h")).tag(6.0)
                        Text(L("24 h")).tag(24.0)
                        Text(L("7 días")).tag(168.0)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }

                Panel(L("Memoria y swap")) {
                    if drawn.count < 2 {
                        EmptyHint(title: loading ? L("Cargando…") : L("Aún no hay historial"), symbol: "clock.arrow.circlepath",
                                  message: L("DevDeck guarda un punto por minuto mientras está abierto. Vuelve en un rato."))
                            .frame(height: 220)
                    } else {
                        Chart {
                            ForEach(drawn) { point in
                                AreaMark(x: .value(L("Hora"), point.date), y: .value("RAM %", point.memPercent))
                                    .foregroundStyle(LinearGradient(colors: [Theme.tint.opacity(0.30), Theme.tint.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                                LineMark(x: .value(L("Hora"), point.date), y: .value("RAM %", point.memPercent), series: .value("s", "ram"))
                                    .foregroundStyle(Theme.tint).lineStyle(StrokeStyle(lineWidth: 1.5))
                                LineMark(x: .value(L("Hora"), point.date), y: .value("Swap %", swapPercent(point)), series: .value("s", "swap"))
                                    .foregroundStyle(Theme.warning).lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                            }
                            ForEach(moments) { moment in
                                PointMark(x: .value(L("Hora"), moment.date), y: .value("RAM %", moment.memPercent))
                                    .foregroundStyle(Theme.danger).symbolSize(40)
                            }
                            if let focus {
                                RuleMark(x: .value(L("Hora"), focus.date)).foregroundStyle(Theme.ink(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { AxisGridLine().foregroundStyle(Theme.ink(0.08)); AxisValueLabel() } }
                        .chartXSelection(value: $selected)
                        .frame(height: 240)
                        HStack(spacing: 14) {
                            legend(Theme.tint, L("RAM usada (%)"))
                            legend(Theme.warning, L("Swap (% de la RAM)"))
                            legend(Theme.danger, L("Momento al límite"))
                            Spacer()
                            Text(L("Pasa el cursor por el gráfico para ver quién usaba la memoria")).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Panel(focus.map { L("Quién usaba la memoria · %@", $0.date.formatted(date: .abbreviated, time: .shortened)) } ?? L("Quién usaba la memoria")) {
                        if let focus {
                            VStack(spacing: 7) {
                                HStack {
                                    Text(L("RAM %@ · swap %@ · CPU %@", "\(Int(focus.memPercent))%", Fmt.bytes(UInt64(focus.swapMB) << 20), "\(Int(focus.cpu))%"))
                                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                                    Spacer()
                                }
                                let top = Double(focus.sources.first?.memMB ?? 1)
                                ForEach(focus.sources.prefix(8), id: \.id) { source in
                                    HStack(spacing: 10) {
                                        Image(systemName: GroupKind(rawValue: source.kind)?.symbol ?? "square").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).frame(width: 18)
                                        Text(source.name).font(.system(size: 13)).lineLimit(1).frame(width: 190, alignment: .leading)
                                        UsageBar(fraction: Double(source.memMB) / max(top, 1), tint: Theme.tint)
                                        Text(Fmt.bytes(UInt64(source.memMB) << 20)).font(.system(size: 12).monospacedDigit()).frame(width: 78, alignment: .trailing)
                                        Text("\(source.cpu)%").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.tertiaryText).frame(width: 44, alignment: .trailing)
                                    }
                                }
                            }
                        } else {
                            Text(L("Sin datos para ese momento")).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    VStack(spacing: 12) {
                        Panel(L("Memoria que solo crece")) {
                            if model.leaks.isEmpty {
                                Text(L("Nada ha crecido sin parar en las últimas 3 horas.")).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                            } else {
                                VStack(spacing: 10) { ForEach(model.leaks.prefix(4)) { LeakRow(leak: $0) } }
                            }
                        }
                        Panel(L("Momentos al límite")) {
                            if moments.isEmpty {
                                Text(L("Ningún momento de memoria al límite en este periodo.")).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(moments.prefix(8)) { moment in
                                        Button { selected = moment.date } label: {
                                            HStack(alignment: .top, spacing: 8) {
                                                Circle().fill(Theme.danger).frame(width: 6, height: 6).padding(.top, 5)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(moment.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12, weight: .medium))
                                                    Text(describe(moment)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2).multilineTextAlignment(.leading)
                                                }
                                                Spacer(minLength: 0)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 380)
                }
            }
            .padding(28)
        }
        .task(id: hours) { await reload() }
    }

    /// The minute under the cursor, or the latest one.
    private var focusPoint: TimelinePoint? {
        guard let selected else { return points.last }
        let minute = Int(selected.timeIntervalSince1970 / 60)
        return points.min { abs($0.minute - minute) < abs($1.minute - minute) }
    }

    private func swapPercent(_ point: TimelinePoint) -> Double {
        let total = Fmt.mb(model.system.memTotal)
        return total > 0 ? min(100, Double(point.swapMB) / total * 100) : 0
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
    }

    private func describe(_ moment: TimelineMoment) -> String {
        let what: String
        switch moment.reason {
        case .pressure: what = L("Presión de memoria crítica (RAM %@)", "\(Int(moment.memPercent))%")
        case .memory: what = L("RAM al %@", "\(Int(moment.memPercent))%")
        case .swap: what = L("El swap saltó a %@", Fmt.bytes(UInt64(moment.swapMB) << 20))
        }
        guard let culprit = moment.culprit else { return what }
        return what + " · " + L("%@ subió %@ en 10 min", culprit, Fmt.bytes(UInt64(moment.culpritGrowthMB) << 20))
    }

    private func reload() async {
        if model.demo { points = model.timeline; return }
        loading = true
        let store = model.timelineStore
        let span = hours
        let loaded = await Task.detached(priority: .userInitiated) { store.load(from: Date().addingTimeInterval(-span * 3600)) }.value
        points = loaded
        loading = false
    }
}

struct LeakRow: View {
    @Environment(AppModel.self) private var model
    let leak: MemoryLeak
    @State private var confirming = false

    var body: some View {
        let group = model.snapshot.group(leak.id)
        let restartable = group.map { $0.kind == .project && !$0.services.isEmpty } ?? false
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(Theme.warning).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(leak.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(L("%@ → %@ en %@ · +%@ por hora", Fmt.bytes(UInt64(leak.fromMB) << 20), Fmt.bytes(UInt64(leak.toMB) << 20), AppModel.hoursText(leak.hours),
                       Fmt.bytes(UInt64(max(0, leak.perHourMB)) << 20)))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 6)
            if restartable, let group {
                Button(L("Reiniciar")) { confirming = true }.buttonStyle(.bordered).controlSize(.small)
                    .confirmationDialog(L("¿Reiniciar %@?", leak.name), isPresented: $confirming) {
                        Button(L("Reiniciar")) { Task { for service in group.services { await model.restart(service: service, in: group) } } }
                    } message: { Text(L("Mismo comando, carpeta y entorno; vuelve en unos segundos")) }
            } else if group == nil {
                Text(L("ya no corre")).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}
