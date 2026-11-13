import DevDeckCore
import SwiftUI

/// Ceilings on what the agents spend. Reaching one only raises a notice.
struct BudgetsPanel: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        let statuses = model.budgetStatuses()
        Panel(L("Presupuestos")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                    if index > 0 { Divider().overlay(Theme.ink(0.05)).padding(.vertical, 9) }
                    BudgetRow(status: status)
                }
                if statuses.isEmpty {
                    Text(L("Pon un tope de tokens a un proyecto, a un agente o a todo, o un porcentaje al límite de una cuenta. DevDeck avisa al 80 % y al 100 %; no detiene nada."))
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
                HStack {
                    Button(L("Añadir presupuesto")) { adding = true }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $adding, arrowEdge: .bottom) { BudgetForm { adding = false } }
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
    }
}

struct BudgetRow: View {
    @Environment(AppModel.self) private var model
    let status: BudgetStatus

    var body: some View {
        let budget = status.budget
        HStack(alignment: .center, spacing: 14) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if status.measurable, status.fraction >= 1 { Pill(text: L("superado"), color: Theme.danger) }
                    else if status.measurable, status.fraction >= 0.8 { Pill(text: L("cerca del tope"), color: Theme.warning) }
                }
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(model.budgetProgress(status)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    Spacer(minLength: 2)
                    if status.measurable { Text("\(Int((status.fraction * 100).rounded()))%").font(.system(size: 12).monospacedDigit()) }
                }
                UsageBar(fraction: status.measurable ? status.fraction : 0, tint: Theme.level(min(status.fraction, 1)))
            }
            .frame(width: 268)
            Button { model.removeBudget(budget.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(L("Quitar presupuesto"))
                .frame(width: 64, alignment: .trailing)
        }
    }

    @ViewBuilder private var icon: some View {
        switch status.budget.kind {
        case .agent: AgentIcon(name: status.budget.target, size: 24)
        case .project: IconTile(symbol: "folder", size: 24)
        case .account: IconTile(symbol: "person.crop.circle", size: 24)
        case .all: IconTile(symbol: "sum", size: 24)
        }
    }

    private var title: String {
        switch status.budget.kind {
        case .all: return L("Todos los agentes")
        case .agent, .account: return status.budget.target
        case .project: return (status.budget.target as NSString).lastPathComponent
        }
    }

    private var caption: String {
        let budget = status.budget
        var parts: [String] = []
        switch budget.kind {
        case .all, .agent: parts.append(budget.period == .day ? L("tokens de hoy") : L("tokens de los últimos 7 días"))
        case .project:
            parts.append(budget.period == .day ? L("tokens de hoy") : L("tokens de los últimos 7 días"))
            parts.append(Fmt.tilde(budget.target))
        case .account: parts.append(L("ventana de %@ de la cuenta", L(budget.windowName)))
        }
        if let resets = status.resetsAt { parts.append(L("reinicia %@", relative(resets))) }
        return parts.joined(separator: " · ")
    }
}

struct BudgetForm: View {
    @Environment(AppModel.self) private var model
    var done: () -> Void

    @State private var kind: Budget.Kind = .project
    @State private var target = ""
    @State private var period: Budget.Period = .week
    @State private var millions: Double = 50
    @State private var percent: Double = 80

    var body: some View {
        let options = targets
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Nuevo presupuesto")).font(.system(size: 13, weight: .semibold))
            Picker(L("Sobre"), selection: $kind) {
                Text(L("Un proyecto")).tag(Budget.Kind.project)
                Text(L("Un agente")).tag(Budget.Kind.agent)
                Text(L("Todos los agentes")).tag(Budget.Kind.all)
                Text(L("Una cuenta")).tag(Budget.Kind.account)
            }
            if kind != .all {
                Picker(kind == .project ? L("Proyecto") : kind == .agent ? L("Agente") : L("Cuenta"), selection: $target) {
                    ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .disabled(options.isEmpty)
            }
            Picker(L("Periodo"), selection: $period) {
                Text(kind == .account ? L("5 h") : L("Hoy")).tag(Budget.Period.day)
                Text(L("7 días")).tag(Budget.Period.week)
            }
            .pickerStyle(.segmented)
            if kind == .account {
                HStack {
                    Text(L("Avisar al llegar a")).font(.system(size: 12))
                    Slider(value: $percent, in: 10...100, step: 5)
                    Text("\(Int(percent))%").font(.system(size: 12).monospacedDigit()).frame(width: 40, alignment: .trailing)
                }
            } else {
                HStack {
                    Text(L("Tope")).font(.system(size: 12))
                    TextField("", value: $millions, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).frame(width: 90)
                    Text(L("millones de tokens")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Text(spentHint).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            HStack {
                Spacer()
                Button(L("Cancelar")) { done() }.buttonStyle(.bordered)
                Button(L("Añadir")) {
                    model.addBudget(Budget(kind: kind, target: kind == .all ? "" : target, period: period,
                                           limit: kind == .account ? percent : millions * 1_000_000))
                    done()
                }
                .buttonStyle(.borderedProminent)
                .disabled((kind != .all && target.isEmpty) || (kind != .account && millions <= 0))
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { if target.isEmpty { target = options.first?.value ?? "" } }
        .onChange(of: kind) { target = targets.first?.value ?? "" }
    }

    private var targets: [(label: String, value: String)] {
        switch kind {
        case .all: return []
        case .agent: return model.agentUsage.installs.map { ($0.name, $0.name) }
        case .account: return model.accounts.accounts.filter { !$0.windows.isEmpty }.map { ("\($0.email) · \($0.agent)", $0.email) }
        case .project:
            var seen = Set<String>()
            return model.agentUsage.byProject(limit: 40).compactMap { item in
                guard !item.project.isEmpty, seen.insert(item.project).inserted else { return nil }
                return (Fmt.tilde(item.project), item.project)
            }
        }
    }

    /// What the chosen target has spent, so the ceiling is set with a reference.
    private var spentHint: String {
        let probe = Budget(kind: kind, target: target, period: period, limit: 1)
        let used = Budgets.status(probe, usage: model.agentUsage, accounts: model.accounts).used
        return L("Gastado en ese periodo: %@ tokens", compact(UInt64(max(0, used))))
    }
}
