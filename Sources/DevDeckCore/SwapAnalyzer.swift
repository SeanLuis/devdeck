import Foundation

public struct SwapInsight: Identifiable, Hashable, Sendable {
    public var id: String { title }
    public let severity: AlertSeverity
    public let symbol: String
    public let title: String
    public let detail: String
}

public struct SwapReport: Sendable {
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    /// MB per minute over the analysis window (positive = growing).
    public var growthMBPerMin: Double = 0
    /// Average bytes/s over the last minute.
    public var swapInRate: Double = 0
    public var swapOutRate: Double = 0
    public var pageInRate: Double = 0
    public var compressed: UInt64 = 0
    public var compressionRatio: Double = 0
    public var thrashing = false
    public var minutesToFull: Double?
    public var insights: [SwapInsight] = []
    /// Groups with the most memory compressed or in swap (estimate).
    public var topOffloaded: [ProcessGroup] = []
    /// Groups reading the most back from disk right now.
    public var topPagers: [ProcessGroup] = []
    /// Killable groups whose closing would bring RAM back to a healthy level.
    public var reliefPlan: [ProcessGroup] = []
    public var reliefBytes: UInt64 = 0

    public var status: AlertSeverity { insights.contains { $0.severity == .critical } ? .critical : insights.contains { $0.severity == .warning } ? .warning : .info }

    public static let empty = SwapReport()
}

/// Explains what swap is doing and who causes it.
public enum SwapAnalyzer {
    static let mb = 1_048_576.0

    public static func analyze(history: [SystemSample], snapshot: Snapshot, windowMinutes: Double = 10) -> SwapReport {
        guard let now = history.last else { return .empty }
        var report = SwapReport()
        report.swapUsed = now.swapUsed
        report.swapTotal = now.swapTotal
        report.compressed = now.memCompressed
        report.compressionRatio = now.compressionRatio

        let windowStart = now.time.addingTimeInterval(-windowMinutes * 60)
        if let past = history.first(where: { $0.time >= windowStart }), now.time.timeIntervalSince(past.time) > 30 {
            let minutes = now.time.timeIntervalSince(past.time) / 60
            report.growthMBPerMin = (Double(now.swapUsed) - Double(past.swapUsed)) / mb / minutes
        }
        let recent = history.filter { $0.time >= now.time.addingTimeInterval(-60) }
        if !recent.isEmpty {
            report.swapInRate = recent.map(\.swapInRate).reduce(0, +) / Double(recent.count)
            report.swapOutRate = recent.map(\.swapOutRate).reduce(0, +) / Double(recent.count)
            report.pageInRate = recent.map(\.pageInRate).reduce(0, +) / Double(recent.count)
        }
        report.thrashing = (report.swapInRate > 5 * mb && report.swapOutRate > 5 * mb)
            || (now.pressure >= 2 && report.swapInRate > 2 * mb)

        let candidates = snapshot.groups.filter { $0.kind != .system && $0.id != Classifier.selfGroupID }
        report.topOffloaded = candidates.filter { $0.offloadedBytes > 64 << 20 }.sorted { $0.offloadedBytes > $1.offloadedBytes }.prefix(6).map { $0 }
        report.topPagers = candidates.filter { $0.pageInRate > 1_048_576 }.sorted { $0.pageInRate > $1.pageInRate }.prefix(5).map { $0 }

        // Relief plan: biggest killable non-system groups until RAM would drop under 75%.
        let target = Double(now.memTotal) * 0.75
        var excess = Double(now.memUsed) - target
        if excess > 0 {
            for group in snapshot.groups where group.killable && group.kind != .system && group.kind != .other && group.memoryBytes > 200 << 20 {
                report.reliefPlan.append(group)
                report.reliefBytes += group.memoryBytes
                excess -= Double(group.memoryBytes)
                if excess <= 0 || report.reliefPlan.count == 3 { break }
            }
        }

        if report.growthMBPerMin > 1, now.swapTotal > now.swapUsed {
            // macOS grows the swap file on demand; use free disk as the real ceiling.
            let headroom = Double(now.diskFree) / mb
            report.minutesToFull = headroom / report.growthMBPerMin
        }

        report.insights = insights(for: report, now: now)
        return report
    }

    static func gb(_ b: Double) -> String { String(format: "%.1f GB", b / 1_073_741_824) }
    static func mbs(_ b: Double) -> String { b >= mb ? String(format: "%.1f MB/s", b / mb) : String(format: "%.0f KB/s", b / 1024) }

    static func insights(for r: SwapReport, now: SystemSample) -> [SwapInsight] {
        var out: [SwapInsight] = []
        let used = Double(r.swapUsed)

        if r.thrashing {
            out.append(SwapInsight(severity: .critical, symbol: "tornado",
                                   title: L("La Mac está “thrashing”"),
                                   detail: L("Escribe %@ a swap y lee %@ a la vez: mueve memoria entre RAM y disco sin parar. Es exactamente lo que se siente como lentitud y tirones. Hay que liberar RAM.", mbs(r.swapOutRate), mbs(r.swapInRate))))
        } else if r.swapInRate > 1 * mb {
            out.append(SwapInsight(severity: .warning, symbol: "arrow.down.doc",
                                   title: L("Leyendo de swap: %@", mbs(r.swapInRate)),
                                   detail: L("Alguna app vuelve a usar memoria que macOS mandó al disco. Notarás esperas al cambiar de app o pestaña.")))
        }
        if r.swapOutRate > 1 * mb && !r.thrashing {
            out.append(SwapInsight(severity: .warning, symbol: "arrow.up.doc",
                                   title: L("Escribiendo a swap: %@", mbs(r.swapOutRate)),
                                   detail: L("Falta RAM ahora mismo y macOS está desalojando memoria al disco.")))
        }
        if r.growthMBPerMin > 50 {
            var detail = L("En los últimos minutos el swap crece %@ MB por minuto.", "\(Int(r.growthMBPerMin))")
            if let minutes = r.minutesToFull, minutes < 240 { detail += " " + L("A este ritmo se comería el disco libre en ~%@ min.", "\(Int(minutes))") }
            out.append(SwapInsight(severity: r.growthMBPerMin > 300 ? .critical : .warning, symbol: "chart.line.uptrend.xyaxis",
                                   title: L("El swap está creciendo"), detail: detail))
        } else if r.growthMBPerMin < -50 {
            out.append(SwapInsight(severity: .info, symbol: "chart.line.downtrend.xyaxis",
                                   title: L("El swap se está liberando"),
                                   detail: L("Baja %@ MB por minuto: lo que cerraste está devolviendo memoria.", "\(Int(-r.growthMBPerMin))")))
        }
        if used > 2 * 1_073_741_824, now.pressure == 1, r.swapInRate < 256 * 1024, r.swapOutRate < 256 * 1024, !r.thrashing {
            out.append(SwapInsight(severity: .info, symbol: "moon.zzz",
                                   title: L("%@ en swap, pero “dormido”", gb(used)),
                                   detail: L("Son páginas viejas que macOS apartó. Mientras no se lean no te frenan. Se liberan al cerrar las apps dueñas o al reiniciar; el tamaño reservado tarda en bajar.")))
        }
        if used < 512 * 1_048_576 {
            out.append(SwapInsight(severity: .info, symbol: "checkmark.seal",
                                   title: L("Swap casi sin uso"), detail: L("La RAM alcanza para lo que tienes abierto.")))
        }
        if r.compressed > 2 << 30 {
            out.append(SwapInsight(severity: r.compressed > 6 << 30 ? .warning : .info, symbol: "archivebox",
                                   title: L("%@ de RAM comprimida (%@×)", gb(Double(r.compressed)), String(format: "%.1f", r.compressionRatio)),
                                   detail: L("Antes de usar swap, macOS comprime memoria en RAM. Comprimir y descomprimir gasta CPU; mucho comprimido = la RAM ya va justa.")))
        }
        if let top = r.topOffloaded.first {
            out.append(SwapInsight(severity: .info, symbol: "person.crop.circle.badge.questionmark",
                                   title: L("Lo que más tiene fuera de RAM: %@", top.name),
                                   detail: L("≈ %@ comprimidos o en swap (estimado). Si no lo estás usando, cerrarlo libera esa memoria de verdad.", gb(Double(top.offloadedBytes)))))
        }
        if let pager = r.topPagers.first {
            out.append(SwapInsight(severity: .warning, symbol: "externaldrive.badge.timemachine",
                                   title: L("%@ está leyendo del disco", pager.name),
                                   detail: L("%@ de page-ins: está recuperando memoria apartada o leyendo archivos sin parar.", mbs(pager.pageInRate))))
        }
        if !r.reliefPlan.isEmpty {
            let names = r.reliefPlan.map(\.name).joined(separator: ", ")
            out.append(SwapInsight(severity: now.pressure > 1 || r.thrashing ? .warning : .info, symbol: "lightbulb",
                                   title: L("Para respirar: cerrar %@", names),
                                   detail: L("Liberaría ~%@ de RAM y dejaría la memoria por debajo del 75%%, con lo que el swap deja de crecer.", gb(Double(r.reliefBytes)))))
        }
        return out
    }
}
