import Charts
import DevDeckCore
import SwiftUI

/// Swap deep-dive: is it active or dormant, how fast it grows, who is offloaded, who is paging, and what to close.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var minutes: Double = 15
    @State private var askedAI = false
    @State private var showRelief = false

    var body: some View {
        let r = model.swapReport
        let s = model.system
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HeroHeader(section: .memory, title: L("Memoria y swap"), subtitle: L("Qué está llenando el swap, si te está frenando y qué cerrar")) {
                    Button { showRelief = true } label: {
                        if model.swapRelieving { ProgressView().controlSize(.small) } else { Label(L("Liberar swap…"), systemImage: "arrow.uturn.backward.circle") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.swapRelieving)
                    Button {
                        askedAI = true
                        model.resetConversation()
                        model.startAgent(L("Analiza mi swap a fondo: qué lo llena, si está activo o dormido, y qué me recomiendas cerrar o reiniciar para bajarlo. Propón las acciones."))
                    } label: { Label(L("Analizar con IA"), systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.agentRunning || !model.aiReady)
                    .help(model.aiReady ? "" : L("Elige un motor de IA en Ajustes"))
                }

                swapHero(r, s)

                // The copilot's analysis, with its plan and with every proposal as a card to approve.
                if askedAI, !model.conversation.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label(L("Análisis del copiloto"), systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                            Text("· \(model.aiEngineLabel)").font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                            Spacer()
                            Button(L("Seguir en el copiloto")) { model.selectedSection = .copilot; model.showConversation() }.buttonStyle(.borderless).font(.system(size: 12))
                            Button { askedAI = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(L("Cerrar"))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        AgentConversationView().frame(height: 380)
                    }
                    .glass(cornerRadius: 12)
                }

                if !r.insights.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(r.insights) { InsightCard(insight: $0) }
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    Panel(L("Swap usado"), symbol: "externaldrive") {
                        SwapUsageChart(minutes: minutes).frame(height: 190)
                    }
                    Panel(L("Actividad: lectura ↑ / escritura ↓"), symbol: "arrow.up.arrow.down") {
                        SwapActivityChart(minutes: minutes).frame(height: 190)
                    }
                }
                Panel(L("Composición de la RAM"), symbol: "square.stack.3d.up") {
                    HStack {
                        Spacer()
                        Picker("", selection: $minutes) {
                            Text("5 min").tag(5.0)
                            Text("15 min").tag(15.0)
                            Text("30 min").tag(30.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    .padding(.top, -34)
                    MemoryCompositionChart(minutes: minutes).frame(height: 210)
                }

                HStack(alignment: .top, spacing: 18) {
                    Panel(L("Quién tiene memoria fuera de la RAM"), symbol: "person.2.crop.square.stack") {
                        OffloadedList(groups: r.topOffloaded)
                    }
                    Panel(L("Plan para liberar RAM"), symbol: "lightbulb") {
                        ReliefPlanView(report: r)
                    }
                    .frame(maxWidth: 420)
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showRelief) { SwapReliefSheet().environment(model) }
    }

    private func swapHero(_ r: SwapReport, _ s: SystemSample) -> some View {
        let state = swapState(r, s)
        return HStack(spacing: 30) {
            RingGauge(value: s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0, lineWidth: 8, semantic: false) {
                VStack(spacing: 2) {
                    Text(Fmt.bytes(s.swapUsed)).font(.system(size: 24, weight: .semibold).monospacedDigit())
                    Text(L("en swap")).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text(L("de %@ reservados", Fmt.bytes(s.swapTotal))).font(.caption2).foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.system(size: 17, weight: .semibold))
                        Text(state.detail).font(.callout).foregroundStyle(Theme.secondaryText)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    StatTile(title: L("Crecimiento"), value: growthText(r.growthMBPerMin), symbol: "chart.line.uptrend.xyaxis",
                             tint: r.growthMBPerMin > 50 ? Theme.danger : Color.primary)
                    StatTile(title: L("Lectura de swap"), value: rate(r.swapInRate), symbol: "arrow.down.doc",
                             tint: r.swapInRate > 1_048_576 ? Theme.warning : Color.primary)
                    StatTile(title: L("Escritura a swap"), value: rate(r.swapOutRate), symbol: "arrow.up.doc",
                             tint: r.swapOutRate > 1_048_576 ? Theme.warning : Color.primary)
                    StatTile(title: s.compressionRatio > 0 ? L("Comprimida · %@×", String(format: "%.1f", s.compressionRatio)) : L("Comprimida"), value: "\(Fmt.bytes(s.memCompressed))", symbol: "archivebox")
                    StatTile(title: L("Presión"), value: L(s.pressureLabel).capitalized, symbol: "gauge.with.needle", tint: .pressure(s.pressure))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .glass(cornerRadius: 12)
    }

    private func swapState(_ r: SwapReport, _ s: SystemSample) -> (title: String, detail: String, symbol: String, color: Color) {
        if r.thrashing {
            return (L("Thrashing: te está frenando"), L("Lee y escribe swap a la vez. Libera RAM ya."), "tornado", Theme.danger)
        }
        if r.swapInRate > 1_048_576 || r.swapOutRate > 1_048_576 {
            return (L("Swap activo"), L("macOS está moviendo memoria entre RAM y disco ahora mismo."), "arrow.triangle.2.circlepath", Theme.warning)
        }
        if s.swapUsed > 1 << 30 {
            return (L("Swap dormido"), L("Hay datos en swap pero no se están usando: no te frena ahora."), "moon.zzz.fill", Theme.tint)
        }
        return (L("Swap tranquilo"), L("La RAM alcanza para lo que tienes abierto."), "checkmark.seal.fill", Theme.success)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        bytesPerSecond >= 1_048_576 ? String(format: "%.1f MB/s", bytesPerSecond / 1_048_576)
            : bytesPerSecond >= 1024 ? String(format: "%.0f KB/s", bytesPerSecond / 1024) : "0"
    }

    private func growthText(_ mbPerMin: Double) -> String {
        abs(mbPerMin) < 1 ? L("estable") : String(format: "%@%.0f MB/min", mbPerMin > 0 ? "+" : "", mbPerMin)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    var tint: Color = .primary
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit()).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(Theme.tertiaryText) }
        }
        .padding(12)
        .frame(minWidth: 120, maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .glass(cornerRadius: 12)
    }
}

struct InsightCard: View {
    let insight: SwapInsight

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.severity(insight.severity).opacity(0.22))
                Image(systemName: insight.symbol).foregroundStyle(Color.severity(insight.severity))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title).font(.system(.callout).weight(.semibold))
                Text(insight.detail).font(.caption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .glass(cornerRadius: 12)
    }
}

struct SwapUsageChart: View {
    @Environment(AppModel.self) private var model
    let minutes: Double

    var body: some View {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        let points = model.systemHistory.filter { $0.time >= cutoff }
        if points.count < 2 {
            EmptyHint(title: L("Recolectando…"), symbol: "chart.xyaxis.line", message: "")
        } else {
            Chart(points, id: \.time) { p in
                AreaMark(x: .value(L("Hora"), p.time), y: .value("GB", Fmt.gb(p.swapUsed)))
                    .foregroundStyle(LinearGradient(colors: [Theme.tint.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value(L("Hora"), p.time), y: .value("GB", Fmt.gb(p.swapUsed)))
                    .foregroundStyle(Theme.tint)
                    .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("GB")
        }
    }
}

struct SwapActivityChart: View {
    @Environment(AppModel.self) private var model
    let minutes: Double

    var body: some View {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        let points = model.systemHistory.filter { $0.time >= cutoff }
        if points.count < 2 {
            EmptyHint(title: L("Recolectando…"), symbol: "chart.bar", message: "")
        } else if points.allSatisfy({ $0.swapInRate < 1024 && $0.swapOutRate < 1024 }) {
            EmptyHint(title: L("Sin actividad de swap"), symbol: "checkmark.circle", message: L("No se está leyendo ni escribiendo swap: no te frena."))
        } else {
            Chart(points, id: \.time) { p in
                BarMark(x: .value(L("Hora"), p.time), y: .value("MB/s", p.swapInRate / 1_048_576))
                    .foregroundStyle(Theme.warning)
                BarMark(x: .value(L("Hora"), p.time), y: .value("MB/s", -p.swapOutRate / 1_048_576))
                    .foregroundStyle(Theme.tint)
            }
            .chartYAxisLabel("MB/s")
        }
    }
}

struct MemoryCompositionChart: View {
    @Environment(AppModel.self) private var model
    let minutes: Double

    struct Slice: Identifiable {
        let id = UUID()
        let time: Date
        let kind: String
        let gb: Double
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        let points = model.systemHistory.filter { $0.time >= cutoff }
        let slices: [Slice] = points.flatMap { p in
            [Slice(time: p.time, kind: "Apps", gb: Fmt.gb(p.memApp)),
             Slice(time: p.time, kind: L("Sistema (wired)"), gb: Fmt.gb(p.memWired)),
             Slice(time: p.time, kind: L("Comprimida"), gb: Fmt.gb(p.memCompressed)),
             Slice(time: p.time, kind: L("Caché de archivos"), gb: Fmt.gb(p.memCached))]
        }
        if points.count < 2 {
            EmptyHint(title: L("Recolectando…"), symbol: "chart.xyaxis.line", message: "")
        } else {
            Chart {
                ForEach(slices) { s in
                    AreaMark(x: .value(L("Hora"), s.time), y: .value("GB", s.gb), stacking: .standard)
                        .foregroundStyle(by: .value(L("Tipo"), s.kind))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("RAM", Fmt.gb(model.system.memTotal)))
                    .foregroundStyle(Theme.ink(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) { Text(L("RAM física")).font(.caption2).foregroundStyle(Theme.secondaryText) }
            }
            .chartForegroundStyleScale(["Apps": Color(hex: 0xE4E4E7), L("Sistema (wired)"): Color(hex: 0x9CA3AF),
                                        L("Comprimida"): Theme.warning.opacity(0.85), L("Caché de archivos"): Color(hex: 0x4B5563)])
            .chartYAxisLabel("GB")
            .chartLegend(position: .bottom)
        }
    }
}

struct OffloadedList: View {
    @Environment(AppModel.self) private var model
    let groups: [ProcessGroup]

    var body: some View {
        if groups.isEmpty {
            EmptyHint(title: L("Nada relevante fuera de RAM"), symbol: "checkmark.seal", message: L("Ningún origen tiene más de 64 MB comprimidos o en swap."))
        } else {
            let maxBytes = Double(groups.first?.offloadedBytes ?? 1)
            VStack(spacing: 10) {
                ForEach(groups) { group in
                    HStack(spacing: 12) {
                        GroupIcon(group: group, size: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(group.name).font(.system(.callout).weight(.medium)).lineLimit(1)
                                if group.pageInRate > 256 * 1024 {
                                    Pill(text: L("lee %@ MB/s", String(format: "%.1f", group.pageInRate / 1_048_576)), color: Theme.warning)
                                }
                            }
                            UsageBar(fraction: Double(group.offloadedBytes) / maxBytes, tint: Theme.tint)
                        }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("≈ \(Fmt.bytes(group.offloadedBytes))").font(.system(.callout).monospacedDigit())
                            Text(L("de %@", Fmt.bytes(group.memoryBytes))).font(.caption2).foregroundStyle(Theme.tertiaryText)
                        }
                        .frame(width: 100, alignment: .trailing)
                        if group.killable {
                            KillButton(title: L("¿Cerrar %@?", group.name), message: L("Libera ~%@ de memoria, incluida la que está en swap.", Fmt.bytes(group.memoryBytes)), compact: true) {
                                await model.kill(group: group)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Text(L("Estimado: memoria del proceso que no está en RAM física (comprimida o en swap)."))
                    .font(.caption2).foregroundStyle(Theme.tertiaryText).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ReliefPlanView: View {
    @Environment(AppModel.self) private var model
    let report: SwapReport

    var body: some View {
        if report.reliefPlan.isEmpty {
            EmptyHint(title: L("No hace falta cerrar nada"), symbol: "leaf", message: L("La RAM está por debajo del 75%."))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Cerrando esto liberas ~%@ y la RAM baja del 75%%:", Fmt.bytes(report.reliefBytes)))
                    .font(.callout).foregroundStyle(Theme.secondaryText)
                ForEach(report.reliefPlan) { group in
                    HStack(spacing: 10) {
                        GroupIcon(group: group, size: 24)
                        Text(group.name).font(.system(.callout).weight(.medium))
                        Spacer()
                        Text(Fmt.bytes(group.memoryBytes)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                        KillButton(title: L("¿Cerrar %@?", group.name), message: L("%@ procesos.", "\(group.processCount)"), label: L("Cerrar")) {
                            await model.kill(group: group)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}
