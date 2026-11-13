import DevDeckCore
import SwiftUI

struct ToolkitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let available = Toolkit.available(env: model.loginEnv)
        let groups = Dictionary(grouping: available, by: \.group)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroHeader(section: .toolkit, title: L("Herramientas"), subtitle: L("Comandos de limpieza y mantenimiento listos para ejecutar, solo de lo que tienes instalado"))
                ForEach(["Docker", "Node", "Python", "Java", "Sistema"], id: \.self) { name in
                    if let recipes = groups[name] {
                        Panel(L(name)) {
                            VStack(spacing: 0) {
                                ForEach(Array(recipes.enumerated()), id: \.element.id) { index, recipe in
                                    if index > 0 { Divider().overlay(Theme.ink(0.05)).padding(.vertical, 8) }
                                    RecipeRow(recipe: recipe)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct RecipeRow: View {
    @Environment(AppModel.self) private var model
    let recipe: ToolRecipe
    @State private var confirming = false

    var body: some View {
        let run = model.recipeRuns[recipe.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(recipe.title)).font(.system(size: 13, weight: .medium))
                    Text(L(recipe.detail)).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    Text(recipe.command.joined(separator: " ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.tertiaryText).textSelection(.enabled)
                }
                Spacer()
                if run?.running == true {
                    ProgressView().controlSize(.small)
                } else {
                    Button(recipe.destructive ? L("Ejecutar…") : L("Ejecutar")) {
                        if recipe.destructive { confirming = true } else { Task { await model.run(recipe) } }
                    }
                    .buttonStyle(.bordered)
                    .frame(width: 96, alignment: .trailing)
                }
            }
            if let run, !run.running, !run.output.isEmpty {
                Text(run.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(run.ok ? Theme.secondaryText : Theme.danger)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.ink(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .confirmationDialog(L(recipe.title), isPresented: $confirming) {
            Button(L("Ejecutar"), role: .destructive) { Task { await model.run(recipe) } }
        } message: {
            Text("\(L(recipe.detail))\n\n\(recipe.command.joined(separator: " "))")
        }
    }
}

struct RecipeRun {
    var running = false
    var ok = true
    var output = ""
}

struct StoredConversation: Codable, Identifiable {
    struct Block: Codable {
        let kind: String
        let text: String
        // Everything needed to show the block again as it was, and to approve a proposed action later.
        var action: AIAction?
        var approval: String?      // pending | done | rejected | failed
        var outcome: String?
        var targetStart: Date?
        var plan: [PlanStep]?
        var argument: String?
        var result: String?
        var seconds: Double?
    }
    var id = UUID()
    var date = Date()
    var title: String
    var blocks: [Block]
}

@MainActor
extension AppModel {
    func run(_ recipe: ToolRecipe) async {
        recipeRuns[recipe.id] = RecipeRun(running: true)
        let result: ShellResult
        if recipe.shell {
            result = await Shell.run("/bin/zsh", ["-c", recipe.command.joined(separator: " ")], env: loginEnv, timeout: 900)
        } else if let exe = LoginEnvironment.which(recipe.command[0], env: loginEnv) {
            result = await Shell.run(exe, Array(recipe.command.dropFirst()), env: loginEnv, timeout: 900)
        } else {
            recipeRuns[recipe.id] = RecipeRun(running: false, ok: false, output: L("No encuentro %@", recipe.command[0]))
            return
        }
        let text = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        // pkill exits 1 when nothing matched: that is a clean "nothing to do".
        let ok = result.ok || (recipe.command.first == "pkill" && result.status == 1)
        recipeRuns[recipe.id] = RecipeRun(running: false, ok: ok, output: text.isEmpty ? (ok ? L("Hecho.") : L("Falló (%@)", "\(result.status)")) : String(text.suffix(1800)))
        pushAlert(AlertEvent(title: L("Herramienta"), message: L(recipe.title), severity: .info))
    }

    // MARK: Conversation history

    func saveConversation() {
        guard let first = conversation.first(where: { $0.kind == .user }) else { return }
        let blocks = conversation.compactMap { item -> StoredConversation.Block? in
            switch item.kind {
            case .user: return .init(kind: "user", text: item.text)
            case .answer: return .init(kind: "answer", text: item.text)
            case .error: return .init(kind: "error", text: item.text)
            case .thought: return item.text.isEmpty ? nil : .init(kind: "thought", text: item.text, seconds: item.seconds)
            case .plan: return .init(kind: "plan", text: "", plan: item.plan)
            case .tool: return .init(kind: "tool", text: item.toolName, argument: item.toolArgument, result: String(item.toolResult.prefix(3500)))
            case .approval:
                guard let action = item.action else { return nil }
                var block = StoredConversation.Block(kind: "action", text: "\(action.type) \(action.target) — \(action.reason)", action: action,
                                                     targetStart: item.targetStart)
                switch item.approval {
                case .pending, .running: block.approval = "pending"
                case .done(let outcome): block.approval = "done"; block.outcome = outcome
                case .failed(let reason): block.approval = "failed"; block.outcome = reason
                case .rejected: block.approval = "rejected"
                }
                return block
            }
        }
        var stored = StoredConversation(title: String(first.text.prefix(80)), blocks: blocks)
        if let id = conversationID, let index = history.firstIndex(where: { $0.id == id }) {
            stored.id = id
            history.remove(at: index)
        }
        conversationID = stored.id
        history.insert(stored, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        store.save(history, "conversations.json")
    }

    func open(_ stored: StoredConversation) {
        stopAgent()
        conversationID = stored.id
        conversation = stored.blocks.map { block in
            switch block.kind {
            case "user": return AgentItem(kind: .user, text: block.text)
            case "error": return AgentItem(kind: .error, text: block.text)
            case "answer":
                var item = AgentItem(kind: .answer, text: block.text)
                item.revealed = block.text.count
                return item
            case "plan": return AgentItem(kind: .plan, plan: block.plan ?? [])
            case "tool":
                var item = AgentItem(kind: .tool, toolName: String(block.text.split(separator: " ").first ?? ""), toolArgument: block.argument ?? "")
                item.toolState = (block.result ?? "").hasPrefix("ERROR") ? .failed : .done
                item.toolResult = block.result ?? ""
                return item
            case "action":
                // Older histories kept only "type target — reason"; rebuild the card from that.
                let action = block.action ?? Self.legacyAction(block.text)
                guard let action else { return AgentItem(kind: .thought, text: block.text) }
                var item = AgentItem(kind: .approval, action: action)
                item.targetStart = block.targetStart
                item.restored = true
                switch block.approval {
                case "done": item.approval = .done(block.outcome ?? "")
                case "failed": item.approval = .failed(block.outcome ?? "")
                case "rejected": item.approval = .rejected
                default: item.approval = .pending
                }
                return item
            default:
                var item = AgentItem(kind: .thought, text: block.text)
                item.seconds = block.seconds ?? 0
                return item
            }
        }
    }

    static func legacyAction(_ text: String) -> AIAction? {
        let parts = text.components(separatedBy: " — ")
        let head = parts[0].split(separator: " ", maxSplits: 1).map(String.init)
        guard head.count == 2, AgentTools.actions[head[0]] != nil else { return nil }
        return AIAction(type: head[0], target: head[1], value: nil, reason: parts.dropFirst().joined(separator: " — "), risk: "medium")
    }

    func deleteHistory() {
        history.removeAll()
        store.save(history, "conversations.json")
    }
}
