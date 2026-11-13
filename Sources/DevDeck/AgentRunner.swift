import DevDeckCore
import Foundation

enum ToolState: String { case running, done, failed }
enum ApprovalState: Equatable {
    case pending, running, done(String), rejected
    /// Could not run (the target no longer exists, the command failed…).
    case failed(String)

    var isSettled: Bool {
        switch self {
        case .done, .rejected, .failed: return true
        default: return false
        }
    }
}

/// One visible block in the copilot conversation (modelled after AI Elements: message, reasoning, plan, tool, confirmation).
struct AgentItem: Identifiable {
    enum Kind { case user, thought, plan, tool, approval, answer, error }
    let id = UUID()
    let kind: Kind
    var text: String = ""
    var plan: [PlanStep] = []
    var toolName: String = ""
    var toolArgument: String = ""
    var toolState: ToolState = .running
    var toolResult: String = ""
    var action: AIAction?
    var approval: ApprovalState = .pending
    var seconds: Double = 0
    var revealed = 0   // characters of `text` already shown (typewriter)
    /// For actions on a pid: when that process started, so an old card can never hit a different process that reused the pid.
    var targetStart: Date?
    /// True when the card was proposed in an earlier run of the app (restored from the history).
    var restored = false
}

@MainActor
extension AppModel {
    func startAgent(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !agentRunning else { return }
        copilotDismissedAt = nil
        agentTask = Task { await runAgent(trimmed) }
        IslandController.shared.update(model: self)
    }

    /// Cards proposed in this run of the app that still wait for a decision.
    var pendingApprovals: [AgentItem] {
        conversation.filter { $0.kind == .approval && $0.approval == .pending && !$0.restored }
    }

    /// The copilot has something to show on the island: it is working, or it waits for a decision.
    var copilotOnIsland: Bool {
        guard agentRunning || !pendingApprovals.isEmpty else { return false }
        return copilotDismissedAt != conversation.count
    }

    /// What the copilot is doing right now, in a few words.
    var copilotStatus: String {
        if let step = conversation.last(where: { $0.kind == .plan })?.plan.first(where: { $0.status == "active" }), agentRunning { return step.title }
        if agentRunning { return L("Pensando…") }
        let pending = pendingApprovals.count
        return pending > 0 ? plural(pending, "%d decisión pendiente", "%d decisiones pendientes") : L("Listo")
    }

    func stopAgent() {
        agentTask?.cancel()
        agentRunning = false
    }

    func resetConversation() {
        stopAgent()
        conversation.removeAll()
        conversationID = nil
    }

    /// Plan → tools → answer, one turn at a time. Read tools run by themselves; actions wait for approval.
    func runAgent(_ question: String) async {
        agentRunning = true
        defer { agentRunning = false; saveConversation() }
        conversation.append(AgentItem(kind: .user, text: question))
        var transcript: [String] = conversation.compactMap { item in
            switch item.kind {
            case .user: return "Usuario: \(item.text)"
            case .answer: return "Asistente: \(item.text)"
            case .approval:
                guard let a = item.action else { return nil }
                let state: String
                switch item.approval {
                case .pending, .running: state = "pendiente de aprobación"
                case .done(let outcome): state = "aprobada y ejecutada → \(outcome.prefix(400))"
                case .failed(let reason): state = "no se pudo ejecutar → \(reason)"
                case .rejected: state = "rechazada por el usuario"
                }
                return "Acción propuesta \(a.type)(\(a.target)): \(state)"
            default: return nil
            }
        }
        var planIndex: Int?
        let instructions = AgentTools.instructions(language: settings.ai.language, recipes: Toolkit.available(env: loginEnv),
                                                   dockerMemoryMB: snapshot.group(Classifier.dockerID) == nil ? nil : DockerDesktop.memoryMiB())
        for turn in 0..<6 {
            if Task.isCancelled { return }
            let started = Date()
            let thoughtItem = AgentItem(kind: .thought)
            let thoughtID = thoughtItem.id
            conversation.append(thoughtItem)
            let step: AgentStep
            do {
                let data = try await backend().structured(instructions: instructions,
                                                          prompt: AgentTools.prompt(snapshotJSON: aiPayload(), transcript: transcript),
                                                          schemaJSON: AgentTools.schemaJSON)
                step = try JSONDecoder().decode(AgentStep.self, from: data)
            } catch {
                conversation.removeAll { $0.id == thoughtID }
                if !Task.isCancelled { conversation.append(AgentItem(kind: .error, text: error.localizedDescription)) }
                return
            }
            if Task.isCancelled { return }
            guard let thoughtIndex = conversation.firstIndex(where: { $0.id == thoughtID }) else { return }
            conversation[thoughtIndex].text = step.thought
            conversation[thoughtIndex].seconds = Date().timeIntervalSince(started)
            if !step.plan.isEmpty {
                if let index = planIndex, conversation.indices.contains(index) {
                    conversation[index].plan = step.plan
                } else {
                    conversation.append(AgentItem(kind: .plan, plan: step.plan))
                    planIndex = conversation.count - 1
                }
            }
            transcript.append("Turno \(turn + 1) · pensamiento: \(step.thought)")

            var ranReadTool = false
            for call in step.tool_calls.prefix(4) {
                if AgentTools.readOnly[call.name] != nil {
                    ranReadTool = true
                    let toolItem = AgentItem(kind: .tool, toolName: call.name, toolArgument: call.argument)
                    conversation.append(toolItem)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let result = runReadTool(call)
                    if let index = conversation.firstIndex(where: { $0.id == toolItem.id }) {
                        conversation[index].toolResult = result
                        conversation[index].toolState = result.hasPrefix("ERROR") ? .failed : .done
                    }
                    transcript.append("Resultado de \(call.name)(\(call.argument)):\n\(result)")
                } else if AgentTools.actions[call.name] != nil {
                    let action = AIAction(type: call.name, target: call.argument, value: call.value, reason: call.reason, risk: risk(for: call))
                    var card = AgentItem(kind: .approval, action: action)
                    card.targetStart = Int32(unredact(call.argument)).flatMap { snapshot.processes[$0]?.startTime }
                    conversation.append(card)
                    transcript.append("Acción propuesta \(call.name)(\(call.argument)): pendiente de aprobación del usuario")
                }
            }
            if let answer = step.answer, !answer.isEmpty, !ranReadTool {
                if let index = planIndex, conversation.indices.contains(index) {
                    conversation[index].plan = conversation[index].plan.map { PlanStep(title: $0.title, status: "done") }
                }
                // Answer goes before the approval cards of this turn, so the cards read as its footer.
                let item = AgentItem(kind: .answer, text: answer)
                let firstApproval = conversation.lastIndex { $0.kind == .thought }.flatMap { thought in
                    conversation.indices.first { $0 > thought && conversation[$0].kind == .approval }
                }
                if let firstApproval { conversation.insert(item, at: firstApproval) } else { conversation.append(item) }
                await typeOut(item.id)
                return
            }
            if !ranReadTool && step.tool_calls.isEmpty {
                conversation.append(AgentItem(kind: .error, text: L("El agente no devolvió respuesta.")))
                return
            }
        }
        conversation.append(AgentItem(kind: .error, text: L("El agente alcanzó el máximo de turnos sin terminar.")))
    }

    private func typeOut(_ id: UUID) async {
        guard let index = conversation.firstIndex(where: { $0.id == id }) else { return }
        let total = conversation[index].text.count
        let stepSize = max(3, total / 90)
        while let i = conversation.firstIndex(where: { $0.id == id }), conversation[i].revealed < total {
            conversation[i].revealed = min(total, conversation[i].revealed + stepSize)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    private func risk(for call: ToolCall) -> String {
        switch call.name {
        case "set_memory_limit": return "low"
        case "run_tool": return Toolkit.recipe(call.argument)?.destructive == false ? "low" : "medium"
        case "clean_cache":
            guard let entry = cacheEntry(path: call.argument) else { return "medium" }
            return entry.safe && services(using: entry).isEmpty ? "low" : "medium"
        case "kill_group": return unredact(call.argument) == Classifier.headlessID ? "low" : "medium"
        default: return "medium"
        }
    }

    func approve(_ id: UUID) async {
        guard let index = conversation.firstIndex(where: { $0.id == id }), let action = conversation[index].action,
              conversation[index].approval == .pending else { return }
        if let reason = staleReason(conversation[index]) {
            conversation[index].approval = .failed(reason)
            saveConversation()
            return
        }
        conversation[index].approval = .running
        let outcome = await apply(action)
        if let i = conversation.firstIndex(where: { $0.id == id }) { conversation[i].approval = .done(outcome) }
        saveConversation()
        IslandController.shared.update(model: self)
    }

    func reject(_ id: UUID) {
        if let index = conversation.firstIndex(where: { $0.id == id }) { conversation[index].approval = .rejected }
        saveConversation()
    }

    /// Puts a settled card (done, rejected or failed) back to "waiting for approval", e.g. after reopening an old conversation.
    func reopen(_ id: UUID) {
        guard let index = conversation.firstIndex(where: { $0.id == id }), conversation[index].approval.isSettled else { return }
        conversation[index].approval = .pending
        saveConversation()
    }

    /// Why a card can no longer be applied safely, if so. Pids are reused by macOS: a card that names a pid is only
    /// valid while that same process (same start time) is alive.
    func staleReason(_ item: AgentItem) -> String? {
        guard let action = item.action, action.type == "kill_process" || action.type == "restart_service" else { return nil }
        guard let pid = Int32(unredact(action.target)), let process = snapshot.processes[pid] else {
            return L("Ese proceso ya no existe.")
        }
        guard let expected = item.targetStart else {
            return item.restored ? L("Esta tarjeta es de una conversación anterior y no sé si el PID sigue siendo el mismo proceso. Vuelve a preguntar.") : nil
        }
        return abs(process.startTime.timeIntervalSince(expected)) < 2 ? nil : L("Ese proceso ya terminó; el PID ahora es de otro proceso.")
    }

    // MARK: Read tools

    private func runReadTool(_ call: ToolCall) -> String {
        let arg = unredact(call.argument)
        func mb(_ b: UInt64) -> String { "\(Int(Fmt.mb(b))) MB" }
        var lines: [String] = []
        switch call.name {
        case "list_groups":
            for g in snapshot.groups.prefix(15) {
                lines.append("\(AISnapshotBuilder.redact(g.id)) [\(g.kind.rawValue)] \(g.name): \(mb(g.memoryBytes)), CPU \(Int(g.cpuPercent))%, \(g.processCount) procs, fuera de RAM ~\(mb(g.offloadedBytes))")
            }
        case "inspect_group":
            guard let g = snapshot.group(arg) ?? snapshot.groups.first(where: { $0.name.lowercased() == arg.lowercased() }) else { return "ERROR: grupo no encontrado" }
            let procs = g.pids.compactMap { snapshot.processes[$0] }.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(12)
            for p in procs {
                let command = settings.ai.shareCommandLines ? AISnapshotBuilder.redact(String(p.commandLine.prefix(120))) : p.name
                lines.append("pid \(p.pid) \(p.name): \(mb(p.memoryBytes)), CPU \(Int(p.cpuPercent))%, activo \(Fmt.duration(since: p.startTime)) · \(command)")
            }
            for s in g.services { lines.append("servicio rootPid \(s.rootPid) [\(s.framework ?? "-")] puertos \(s.ports) \(mb(s.memoryBytes))") }
        case "list_ports":
            for p in snapshot.ports.prefix(30) {
                lines.append(":\(p.port) \(p.groupName) [\(p.groupKind.rawValue)] \(p.container ?? p.framework ?? p.processName) pid \(p.pid) \(mb(p.memoryBytes))")
            }
        case "swap_report":
            let r = swapReport
            lines.append("swap \(mb(r.swapUsed)) de \(mb(r.swapTotal)); crecimiento \(Int(r.growthMBPerMin)) MB/min; lectura \(Int(r.swapInRate / 1024)) KB/s; escritura \(Int(r.swapOutRate / 1024)) KB/s; thrashing \(r.thrashing); comprimida \(mb(r.compressed)) (\(String(format: "%.1f", r.compressionRatio))x)")
            for i in r.insights { lines.append("- \(i.title): \(i.detail)") }
            for g in r.topOffloaded { lines.append("fuera de RAM: \(g.name) ~\(mb(g.offloadedBytes)) de \(mb(g.memoryBytes)) (id \(AISnapshotBuilder.redact(g.id)))") }
        case "list_caches":
            let all = (allProjectCaches + globalCaches).filter { arg.isEmpty || ($0.projectRoot ?? $0.label).lowercased().contains(arg.lowercased()) }
            for c in all.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(20) {
                lines.append("\(AISnapshotBuilder.redact(c.path)) \(mb(c.sizeBytes)) [\(c.kind.rawValue)] regenerable=\(c.safe) enUso=\(!services(using: c).isEmpty)")
            }
        case "agent_usage":
            for agent in agentUsage.agents {
                let week = agentUsage.total(agent: agent), today = agentUsage.total(agent: agent, day: AgentUsageReport.dayString(Date()))
                lines.append("\(agent): hoy \(today.billable) tokens (\(today.messages) respuestas), 7 días \(week.billable) tokens, caché leída \(week.cacheRead)")
            }
            for p in agentUsage.byProject(limit: 6) { lines.append("proyecto \((p.project as NSString).lastPathComponent) [\(p.agent)]: \(p.tokens.billable) tokens") }
            for g in snapshot.groups where g.kind == .agent { lines.append("en ejecución: \(g.name) \(mb(g.memoryBytes)), \(g.processCount) procs (id \(g.id))") }
        case "project_info":
            guard let g = snapshot.groups.first(where: { $0.kind == .project && $0.name.lowercased().contains(arg.lowercased()) }) else {
                let known = projectsList.filter { $0.name.lowercased().contains(arg.lowercased()) }.prefix(3).map(\.name)
                return known.isEmpty ? "ERROR: proyecto no encontrado" : "No está corriendo. Coincidencias en disco: \(known.joined(separator: ", "))"
            }
            lines.append("\(g.name) (id \(AISnapshotBuilder.redact(g.id))): \(mb(g.memoryBytes)), \(g.services.count) servicios, contenedores \(g.containers.filter(\.isRunning).count)")
            for s in g.services { lines.append("servicio rootPid \(s.rootPid) [\(s.framework ?? "-")] \(s.label) puertos \(s.ports) \(mb(s.memoryBytes)) activo \(Fmt.duration(since: s.startTime))") }
            for c in (projectCaches[g.projectRoot ?? ""] ?? []).prefix(6) { lines.append("caché \(AISnapshotBuilder.redact(c.path)) \(mb(c.sizeBytes)) regenerable=\(c.safe)") }
        default:
            return "ERROR: herramienta desconocida"
        }
        return lines.isEmpty ? "(sin datos)" : String(lines.joined(separator: "\n").prefix(3500))
    }
}
