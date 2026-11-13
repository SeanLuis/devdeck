import DevDeckCore
import SwiftUI

/// The copilot conversation: user message, reasoning, plan, tool calls, answer and inline approvals.
struct AgentConversationView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.conversation) { item in
                        row(item)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.spring(duration: 0.32, bounce: 0.12), value: model.conversation.count)
            }
            .onChange(of: model.conversation.count) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.conversation.last?.revealed) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(_ item: AgentItem) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.ink(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.top, 6)
        case .thought: ThoughtRow(item: item)
        case .plan: PlanCard(steps: item.plan)
        case .tool: ToolRow(item: item)
        case .approval: ApprovalCard(item: item)
        case .answer: AnswerBlock(item: item)
        case .error:
            Label(item.text, systemImage: "exclamationmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.danger)
        }
    }
}

/// "Pensando…" with a soft shimmer, then a collapsed "Pensó 3 s".
struct ThoughtRow: View {
    let item: AgentItem
    @State private var open = false
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.text.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Pensando…")).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                }
                .opacity(phase > 0 ? 1 : 0.45)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 1 } }
            } else {
                Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                        Text(L("Pensó %@ s", String(format: "%.0f", max(1, item.seconds)))).font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                if open {
                    Text(item.text).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                        .padding(.leading, 14)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.ink(0.12)).frame(width: 1.5) }
                }
            }
        }
    }
}

/// Text with a light sweeping across it while something is in progress (AI Elements' "shimmer").
struct Shimmer: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        if active {
            content
                .foregroundStyle(Theme.secondaryText)
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.primary, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.5)
                            .offset(x: geo.size.width * phase)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.1 } }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View { modifier(Shimmer(active: active)) }
}

/// The agent's plan as a collapsible card: title, progress, and the steps joined by a line
/// (done → check, current → spinner and shimmer, pending → hollow dot). It folds itself once everything is done.
struct PlanCard: View {
    let steps: [PlanStep]
    @State private var userOpen: Bool?

    private var doneCount: Int { steps.filter { $0.status == "done" }.count }
    private var finished: Bool { !steps.isEmpty && doneCount == steps.count }
    private var open: Bool { userOpen ?? !finished }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.22)) { userOpen = !open } } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: finished ? "checklist.checked" : "checklist").font(.system(size: 13)).foregroundStyle(Theme.secondaryText).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("Plan")).font(.system(size: 13, weight: .semibold))
                        Text(summary).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).lineLimit(1).shimmer(!finished)
                    }
                    Spacer(minLength: 8)
                    Text("\(doneCount)/\(steps.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiaryText)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        PlanStepRow(step: step, isLast: index == steps.count - 1)
                    }
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .glass(cornerRadius: 10)
        .animation(.snappy(duration: 0.2), value: steps)
    }

    private var summary: String {
        if finished { return plural(steps.count, "Completado · %d paso", "Completado · %d pasos") }
        return steps.first { $0.status == "active" }?.title ?? steps.first { $0.status == "pending" }?.title ?? L("Preparando…")
    }
}

struct PlanStepRow: View {
    let step: PlanStep
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                ZStack {
                    switch step.status {
                    case "done": Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    case "active": ProgressView().controlSize(.mini).scaleEffect(0.85)
                    default: Circle().strokeBorder(Theme.ink(0.25), lineWidth: 1.2).frame(width: 11, height: 11)
                    }
                }
                .frame(width: 18, height: 18)
                if !isLast { Rectangle().fill(Theme.ink(0.12)).frame(width: 1).frame(minHeight: 8) }
            }
            Text(step.title)
                .font(.system(size: 13, weight: step.status == "active" ? .medium : .regular))
                .foregroundStyle(step.status == "pending" ? Theme.tertiaryText : step.status == "done" ? Theme.secondaryText : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
                .padding(.bottom, isLast ? 0 : 8)
            Spacer(minLength: 0)
        }
    }
}

/// A read tool the agent ran: name, argument, a status badge, and (expanded) its parameters and result.
struct ToolRow: View {
    let item: AgentItem
    @State private var open = false

    static let titles: [String: String] = [
        "list_groups": "Revisó los mayores consumidores", "inspect_group": "Inspeccionó procesos", "list_ports": "Revisó los puertos",
        "swap_report": "Analizó el swap", "list_caches": "Revisó las cachés", "agent_usage": "Revisó el uso de agentes",
        "project_info": "Consultó el proyecto",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 18)
                    Text(L(Self.titles[item.toolName] ?? item.toolName)).font(.system(size: 13, weight: .medium))
                    if !item.toolArgument.isEmpty {
                        Text(item.toolArgument).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.tertiaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    StatusBadge(state: item.toolState)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                if !item.toolArgument.isEmpty { block(L("Parámetros"), item.toolArgument) }
                block(L("Resultado"), item.toolResult.isEmpty ? "…" : item.toolResult)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .glass(cornerRadius: 10)
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium)).kerning(0.4).foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(item.toolState == .failed ? Theme.danger : Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.ink(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct StatusBadge: View {
    let state: ToolState

    var body: some View {
        HStack(spacing: 4) {
            switch state {
            case .running: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            case .done: Image(systemName: "checkmark.circle").font(.system(size: 10))
            case .failed: Image(systemName: "xmark.circle").font(.system(size: 10))
            }
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(state == .failed ? Theme.danger : Theme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Theme.ink(0.06), in: Capsule())
    }

    private var label: String {
        switch state {
        case .running: return L("En curso")
        case .done: return L("Listo")
        case .failed: return L("Error")
        }
    }
}

/// An action the agent proposes; nothing runs until the user approves it here.
/// Request on top, decision at the bottom right; once decided it shows what happened and can be proposed again.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    let item: AgentItem

    var body: some View {
        if let action = item.action {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(action.type)).font(.system(size: 13)).foregroundStyle(Theme.secondaryText).frame(width: 18).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title(action)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Pill(text: action.risk == "low" ? L("riesgo bajo") : L("requiere cuidado"), color: action.risk == "low" ? Theme.success : Theme.warning)
                        }
                        Text(action.reason).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        if let detail = detail(action) {
                            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                footer
            }
            .padding(12)
            .frame(maxWidth: 620, alignment: .leading)
            .glass(cornerRadius: 10)
            .animation(.snappy(duration: 0.25), value: item.approval)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch item.approval {
        case .pending:
            HStack(spacing: 8) {
                if item.restored {
                    Text(L("De una conversación anterior: al aprobar se valida contra el estado actual."))
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                }
                Spacer(minLength: 8)
                Button(L("Rechazar")) { withAnimation(.snappy) { model.reject(item.id) } }.buttonStyle(.bordered)
                Button(L("Aprobar")) { Task { await model.approve(item.id) } }.buttonStyle(.borderedProminent)
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Ejecutando…")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).shimmer(true)
                Spacer()
            }
        case .done(let outcome):
            settled(symbol: "checkmark.circle.fill", color: Theme.success, label: L("Aprobada"), text: outcome)
        case .failed(let reason):
            settled(symbol: "exclamationmark.triangle.fill", color: Theme.warning, label: L("No se ejecutó"), text: reason)
        case .rejected:
            settled(symbol: "xmark.circle", color: Theme.tertiaryText, label: L("Rechazada"), text: "")
        }
    }

    private func settled(symbol: String, color: Color, label: String, text: String) -> some View {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.ink(0.05))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(color).frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 12, weight: .medium))
                    if let first = lines.first, !first.isEmpty {
                        Text(first).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button(L("Volver a proponer")) { withAnimation(.snappy) { model.reopen(item.id) } }
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .help(L("Deja la tarjeta lista para aprobarla otra vez"))
            }
            if lines.count > 1, !lines[1].isEmpty {
                Text(lines[1])
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Theme.ink(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "kill_group", "kill_process": return "xmark.circle"
        case "restart_service": return "arrow.clockwise"
        case "clean_cache": return "trash"
        case "run_tool": return "wrench.and.screwdriver"
        case "set_docker_memory": return "shippingbox"
        default: return "bell.badge"
        }
    }

    private func title(_ action: AIAction) -> String { model.title(for: action) }

    /// The exact command or the fine print of what approving will do.
    private func detail(_ action: AIAction) -> String? {
        switch action.type {
        case "run_tool": return Toolkit.recipe(action.target)?.commandLine
        case "set_memory_limit": return L("Solo crea una alerta. No reduce la memoria ni cierra nada.")
        case "set_docker_memory":
            let now = DockerDesktop.memoryMiB().map { L("Ahora: %d MB. ", $0) } ?? ""
            return now + L("Reinicia Docker Desktop: los contenedores se detienen un momento.")
        default: return nil
        }
    }
}

struct AnswerBlock: View {
    @Environment(AppModel.self) private var model
    let item: AgentItem
    @State private var copied = false

    var body: some View {
        let shown = String(item.text.prefix(max(item.revealed, 0)))
        VStack(alignment: .leading, spacing: 8) {
            Text((try? AttributedString(markdown: shown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(shown))
                .font(.system(size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: 680, alignment: .leading)
            if item.revealed >= item.text.count {
                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        copied = true
                    } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help(L("Copiar"))
                    Button {
                        if let last = model.conversation.last(where: { $0.kind == .user })?.text { model.startAgent(last) }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help(L("Volver a preguntar"))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
    }
}
