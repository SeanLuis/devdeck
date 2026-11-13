import Foundation

public struct PlanStep: Codable, Hashable, Sendable, Identifiable {
    public var id: String { title }
    public let title: String
    public let status: String   // pending | active | done

    public init(title: String, status: String) {
        self.title = title
        self.status = status
    }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public let name: String
    public let argument: String
    public let value: Double?
    public let reason: String
}

/// One turn of the copilot agent: what it thinks, its plan, the tools it wants, and (when finished) the answer.
public struct AgentStep: Codable, Hashable, Sendable {
    public let thought: String
    public let plan: [PlanStep]
    public let tool_calls: [ToolCall]
    public let answer: String?
}

public enum AgentTools {
    /// Read-only tools run automatically; action tools always wait for the user's approval.
    public static let readOnly: [String: String] = [
        "list_groups": "Top consumidores de RAM/CPU (proyectos, agentes, apps). argument: \"\"",
        "inspect_group": "Procesos de un grupo con RAM, CPU y comando. argument: id del grupo",
        "list_ports": "Puertos en escucha con proyecto y servidor. argument: \"\"",
        "swap_report": "Análisis de swap: actividad, crecimiento, quién está fuera de RAM. argument: \"\"",
        "list_caches": "Cachés en disco por tamaño. argument: nombre de proyecto o \"\" para todas",
        "agent_usage": "Tokens y sesiones de Claude Code/Codex (7 días). argument: \"\"",
        "project_info": "Servicios, puertos y cachés de un proyecto. argument: nombre del proyecto",
    ]
    public static let actions: [String: String] = [
        "kill_group": "Cerrar un grupo de procesos. argument: id del grupo",
        "kill_process": "Matar un proceso. argument: pid",
        "restart_service": "Reiniciar un servidor de desarrollo con su mismo comando y entorno. argument: rootPid",
        "clean_cache": "Borrar una caché. argument: path exacto",
        "set_memory_limit": "Crear una ALERTA que avisa cuando un grupo pasa de cierta RAM. No reduce la memoria ni cierra nada. argument: id del grupo, value: MB",
        "set_docker_memory": "Reducir de verdad la RAM de Docker: cambia el tamaño de la VM de Docker Desktop y lo reinicia (los contenedores se detienen un momento). argument: \"docker\", value: MB (mínimo 2048)",
        "run_tool": "Ejecutar una receta de mantenimiento de la sección Herramientas (limpiezas de Docker, npm, pnpm, Homebrew, Xcode…). argument: id de la receta",
    ]

    public static let schemaJSON: String = {
        let names = Array(readOnly.keys).sorted() + Array(actions.keys).sorted()
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["thought", "plan", "tool_calls", "answer"],
            "properties": [
                "thought": ["type": "string"],
                "plan": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["title", "status"],
                    "properties": ["title": ["type": "string"], "status": ["type": "string", "enum": ["pending", "active", "done"]]],
                ]],
                "tool_calls": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false, "required": ["name", "argument", "value", "reason"],
                    "properties": ["name": ["type": "string", "enum": names], "argument": ["type": "string"],
                                   "value": ["type": ["number", "null"]], "reason": ["type": "string"]],
                ]],
                "answer": ["type": ["string", "null"]],
            ],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }()

    public static func instructions(language: String, recipes: [ToolRecipe] = [], dockerMemoryMB: Int? = nil) -> String {
        let tools = recipes.isEmpty ? "(ninguna instalada)" : recipes.map { "- \($0.id): \($0.title). \($0.detail) [\($0.commandLine)]" }.joined(separator: "\n")
        let docker = dockerMemoryMB.map { "La VM de Docker Desktop tiene asignados \($0) MB." } ?? ""
        let read = readOnly.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        let act = actions.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        return """
        Eres el copiloto de DevDeck, un agente que ayuda a un desarrollador a entender y controlar la carga de su Mac. Trabajas por turnos.
        En cada turno devuelves JSON con: "thought" (una frase de razonamiento), "plan" (2-5 pasos cortos con estado pending/active/done, \
        actualizado en cada turno), "tool_calls" (herramientas que necesitas ahora) y "answer" (null mientras necesites herramientas; \
        el texto final en \(language), markdown simple, cuando ya puedas responder).
        Herramientas de lectura (se ejecutan solas):
        \(read)
        Acciones (NO se ejecutan solas: el usuario las aprueba con un botón dentro de tu respuesta; proponlas con "reason" claro):
        \(act)
        Recetas disponibles para run_tool (usa el id exacto; no inventes comandos):
        \(tools)
        \(docker) Si el usuario quiere que Docker use menos memoria, la acción correcta es set_docker_memory; set_memory_limit solo avisa.
        Reglas: usa solo ids, pids y rutas que aparezcan en el snapshot o en resultados de herramientas. No toques grupos "system". \
        Pide como mucho 3 herramientas por turno. Si el snapshot ya basta, responde sin herramientas. Cuando propongas acciones, \
        ponlas en tool_calls del mismo turno en que das la "answer" y explica en la respuesta qué hace cada una. Sé breve y concreto, con cifras. \
        Formato de la respuesta: párrafos cortos, **negritas** y listas con guiones. Nunca tablas, encabezados (#) ni emojis.
        """
    }

    public static func prompt(snapshotJSON: String, transcript: [String]) -> String {
        "Snapshot del sistema:\n\(snapshotJSON)\n\nConversación y resultados hasta ahora:\n" + transcript.joined(separator: "\n\n") + "\n\nDevuelve el siguiente turno."
    }
}
