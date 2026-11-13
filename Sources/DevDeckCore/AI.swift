import Foundation

public struct AIFinding: Codable, Hashable, Sendable {
    public let title: String
    public let detail: String
    public let severity: String
    public let group: String
}

public struct AIAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(type)|\(target)" }
    public let type: String
    public let target: String
    public let value: Double?
    public let reason: String
    public let risk: String

    public init(type: String, target: String, value: Double?, reason: String, risk: String) {
        self.type = type; self.target = target; self.value = value; self.reason = reason; self.risk = risk
    }

    public var title: String {
        switch type {
        case "kill_group": return L("Cerrar grupo")
        case "kill_process": return L("Matar proceso %@", target)
        case "restart_service": return L("Reiniciar servicio %@", target)
        case "clean_cache": return L("Limpiar caché")
        case "set_memory_limit": return L("Avisar si pasa de %@ MB", "\(Int(value ?? 0))")
        case "set_docker_memory": return L("Reducir Docker a %@ MB", "\(Int(value ?? 0))")
        case "run_tool": return Toolkit.recipe(target).map { L($0.title) } ?? L("Ejecutar %@", target)
        default: return type
        }
    }
}

public struct AIDiagnosis: Codable, Hashable, Sendable {
    public let summary: String
    public let findings: [AIFinding]
    public let actions: [AIAction]
}

public struct AIChatTurn: Codable, Hashable, Sendable {
    public let role: String   // "user" | "assistant"
    public let text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

public enum AIError: LocalizedError {
    case missingKey
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return L("Falta la API key de OpenAI. Pégala en Ajustes → IA.")
        case .http(let code, let message): return code == 401 ? L("La API key no es válida (401).") : L("OpenAI respondió %@: %@", "\(code)", message)
        case .badResponse(let detail): return L("Respuesta inesperada de OpenAI: %@", detail)
        }
    }
}

/// Where the API key lives. Never logged, never sent anywhere but the configured endpoint.
public enum AIKeyProvider {
    public static func secretsURL(store: JSONStore) -> URL { store.directory.appendingPathComponent("secrets.json") }

    public static func key(config: AIConfig, store: JSONStore) -> String? {
        if let stored = storedKey(store: store) { return stored }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        if let path = config.envFilePath, let key = readEnvFile(path, variable: "OPENAI_API_KEY") { return key }
        return nil
    }

    public static func storedKey(store: JSONStore) -> String? {
        guard let data = try? Data(contentsOf: secretsURL(store: store)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = obj["openai"], !key.isEmpty else { return nil }
        return key
    }

    public static func store(key: String, store: JSONStore) throws {
        let url = secretsURL(store: store)
        let data = try JSONSerialization.data(withJSONObject: ["openai": key])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func removeKey(store: JSONStore) {
        try? FileManager.default.removeItem(at: secretsURL(store: store))
    }

    /// "sk-…AbCd"
    public static func masked(_ key: String) -> String {
        guard key.count > 10 else { return "••••" }
        return String(key.prefix(3)) + "…" + String(key.suffix(4))
    }

    public static func readEnvFile(_ path: String, variable: String) -> String? {
        guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix(variable + "=") else { continue }
            var value = String(line.dropFirst(variable.count + 1)).trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Compact, redacted description of the machine for the model.
public enum AISnapshotBuilder {
    public static func redact(_ text: String) -> String {
        var out = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let rules: [(String, String)] = [
            (#"(?i)((?:api[_-]?key|token|secret|password|passwd|auth|bearer)[A-Za-z0-9_\-]*\s*[=:]\s*)\S+"#, "$1***"),
            (#"(?i)(--(?:api[_-]?key|token|secret|password)[=\s])\S+"#, "$1***"),
            (#"\b(sk-[A-Za-z0-9_\-]{8,}|ghp_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|xox[abp]-[A-Za-z0-9-]{10,})"#, "***"),
            (#"(://[^:/\s]+:)[^@/\s]+@"#, "$1***@"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    public static func build(snapshot: Snapshot, system: SystemSample, caches: [CacheEntry], alerts: [AlertEvent],
                             memoryTrendMB: [String: Double], swap: SwapReport = .empty, includeCommands: Bool = true) -> String {
        func mb(_ b: UInt64) -> Int { Int(Fmt.mb(b)) }
        let groups: [[String: Any]] = snapshot.groups.prefix(18).map { g in
            var item: [String: Any] = [
                "id": redact(g.id), "kind": g.kind.rawValue, "name": g.name, "memMB": mb(g.memoryBytes),
                "cpuPct": Int(g.cpuPercent), "processes": g.processCount, "killable": g.killable,
            ]
            if g.offloadedBytes > 32 << 20 { item["compressedOrSwappedMB_est"] = mb(g.offloadedBytes) }
            if g.pageInRate > 64 * 1024 { item["pageInMBps"] = round1(g.pageInRate / 1_048_576) }
            if let trend = memoryTrendMB[g.id] { item["memChange10minMB"] = Int(trend) }
            if !g.ports.isEmpty { item["ports"] = Array(Set(g.ports.map { Int($0.port) })).sorted() }
            if !g.services.isEmpty {
                item["services"] = g.services.prefix(6).map { s -> [String: Any] in
                    var svc: [String: Any] = ["rootPid": Int(s.rootPid), "framework": s.framework ?? "", "memMB": mb(s.memoryBytes),
                                              "cpuPct": Int(s.cpuPercent), "ports": s.ports.map(Int.init), "uptime": Fmt.duration(since: s.startTime)]
                    svc["command"] = includeCommands ? redact(String(s.command.prefix(160))) : s.label
                    return svc
                }
            }
            if !g.origins.isEmpty { item["launchedBy"] = g.origins }
            if !g.containers.isEmpty {
                let running: [ContainerInfo] = g.containers.filter(\.isRunning)
                item["containersRunning"] = running.count
                item["containersTotal"] = g.containers.count
                // Running ones first: a long tail of stopped containers must not hide the live ones.
                let byMemory: [ContainerInfo] = running.sorted { ($0.memoryBytes ?? 0) > ($1.memoryBytes ?? 0) }
                let stopped: [ContainerInfo] = g.containers.filter { !$0.isRunning }
                let ordered: [ContainerInfo] = byMemory + stopped
                item["containers"] = ordered.prefix(10).map { c -> [String: Any] in
                    ["name": c.name, "state": c.state, "memMB": Int(Fmt.mb(c.memoryBytes ?? 0))]
                }
            }
            if g.kind != .project && g.kind != .system {
                let top: [ProcessRecord] = Array(g.pids.compactMap { snapshot.processes[$0] }.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(4))
                item["topProcesses"] = top.map { p -> [String: Any] in
                    var proc: [String: Any] = ["pid": Int(p.pid), "name": p.name, "memMB": mb(p.memoryBytes), "cpuPct": Int(p.cpuPercent)]
                    if includeCommands { proc["command"] = redact(String(p.commandLine.prefix(140))) }
                    return proc
                }
            }
            return item
        }
        let cacheList: [[String: Any]] = caches.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(25).map { c in
            var item: [String: Any] = ["path": redact(c.path), "kind": c.kind.rawValue, "sizeMB": mb(c.sizeBytes), "regenerable": c.safe]
            if let root = c.projectRoot {
                item["project"] = (root as NSString).lastPathComponent
                item["projectRunning"] = snapshot.group(forProject: root) != nil
            }
            return item
        }
        let swapInfo: [String: Any] = [
            "usedGB": round1(Fmt.gb(system.swapUsed)), "reservedGB": round1(Fmt.gb(system.swapTotal)),
            "growthMBPerMin": Int(swap.growthMBPerMin), "swapInMBps": round1(swap.swapInRate / 1_048_576),
            "swapOutMBps": round1(swap.swapOutRate / 1_048_576), "compressedGB": round1(Fmt.gb(system.memCompressed)),
            "compressionRatio": round1(system.compressionRatio), "thrashing": swap.thrashing,
        ]
        let payload: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: snapshot.time),
            "system": [
                "memTotalGB": round1(Fmt.gb(system.memTotal)), "memUsedGB": round1(Fmt.gb(system.memUsed)),
                "memPct": Int(system.memPercent), "pressure": system.pressureLabel,
                "cpuPct": Int(system.cpuPercent), "diskFreeGB": Int(Fmt.gb(system.diskFree)),
                "headlessBrowsers": snapshot.headlessBrowserCount,
            ],
            "swap": swapInfo,
            "groups": groups,
            "caches": cacheList,
            "recentAlerts": alerts.prefix(8).map { "\($0.title): \($0.message)" },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// OpenAI Responses API client.
public struct OpenAIClient: Sendable {
    public let config: AIConfig
    public let apiKey: String
    /// What the call is for, for DevDeck's own usage ledger: "copilot" or "automatic".
    public var purpose = "copilot"

    public init(config: AIConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
    }

    var instructions: String {
        """
        Eres el copiloto de DevDeck, un panel de control para desarrolladores en macOS. Recibes un snapshot JSON de la máquina: \
        RAM, presión de memoria, swap (uso, crecimiento, lectura/escritura por segundo, memoria comprimida, thrashing), CPU, disco, \
        grupos de procesos (proyectos con sus servidores de desarrollo, agentes de IA como Claude Code o Devin, navegadores headless, \
        Docker, apps) y cachés en disco. "compressedOrSwappedMB_est" estima la memoria de un grupo que está comprimida o en swap.
        Tu trabajo: explicar en \(config.language), claro y directo, de dónde viene la carga, qué es anómalo y qué hacer. \
        Presta especial atención al swap: distingue swap "dormido" (inofensivo) de swap activo (lectura/escritura = lentitud).
        Reglas:
        - Usa SOLO ids, pids y rutas que existan en el snapshot. Nunca inventes.
        - Acciones posibles: kill_group (target = id de grupo), kill_process (target = pid), restart_service (target = rootPid de un servicio), \
        clean_cache (target = path exacto de "caches"), set_memory_limit (target = id de grupo, value = MB; solo crea una alerta, no reduce memoria), \
        set_docker_memory (target = "docker", value = MB; cambia la RAM de la VM de Docker Desktop y lo reinicia), \
        run_tool (target = id de receta: \(Toolkit.recipes.map(\.id).joined(separator: ", "))).
        - Nunca propongas tocar grupos "system" ni con killable=false.
        - risk "low" solo si no se pierde trabajo: cerrar navegadores headless, limpiar cachés regenerables de proyectos que NO están corriendo. \
        Matar agentes de IA, servidores de dev en uso o Docker es "medium" o "high".
        - Si no hace falta actuar, devuelve actions vacío. Máximo \(config.maxActions) acciones, las de más impacto primero.
        """
    }

    static let diagnosisSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["summary", "findings", "actions"],
        "properties": [
            "summary": ["type": "string"],
            "findings": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["title", "detail", "severity", "group"],
                "properties": [
                    "title": ["type": "string"], "detail": ["type": "string"],
                    "severity": ["type": "string", "enum": ["info", "warning", "critical"]],
                    "group": ["type": "string"],
                ],
            ]],
            "actions": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["type", "target", "value", "reason", "risk"],
                "properties": [
                    "type": ["type": "string", "enum": ["kill_group", "kill_process", "restart_service", "clean_cache", "set_memory_limit", "set_docker_memory", "run_tool"]],
                    "target": ["type": "string"], "value": ["type": ["number", "null"]],
                    "reason": ["type": "string"], "risk": ["type": "string", "enum": ["low", "medium", "high"]],
                ],
            ]],
        ],
    ]

    var base: String { config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }

    func withReasoning(_ body: [String: Any]) -> [String: Any] {
        guard config.reasoningEffort != .auto else { return body }
        var b = body
        b["reasoning"] = ["effort": config.reasoningEffort.rawValue]
        return b
    }

    public func diagnose(snapshotJSON: String, focus: String?) async throws -> AIDiagnosis {
        var prompt = "Snapshot del sistema:\n\(snapshotJSON)\n\n"
        prompt += focus.map { "Pregunta concreta del usuario: \($0)" } ?? "Diagnostica el estado actual y propone acciones si hacen falta."
        let body: [String: Any] = [
            "model": config.model,
            "instructions": instructions,
            "input": prompt,
            "text": ["format": ["type": "json_schema", "name": "diagnosis", "strict": true, "schema": Self.diagnosisSchema]],
        ]
        let text = try await send(withReasoning(body), fallback: body)
        guard let data = text.data(using: .utf8) else { throw AIError.badResponse(L("vacía")) }
        do { return try JSONDecoder().decode(AIDiagnosis.self, from: data) }
        catch { throw AIError.badResponse(String(text.prefix(200))) }
    }

    public func structured(instructions: String, prompt: String, schemaJSON: String) async throws -> Data {
        let schema = (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) ?? [:]
        let body: [String: Any] = [
            "model": config.model, "instructions": instructions, "input": prompt,
            "text": ["format": ["type": "json_schema", "name": "step", "strict": true, "schema": schema]],
        ]
        return Data(try await send(withReasoning(body), fallback: body).utf8)
    }

    func chatBody(history: [AIChatTurn], snapshotJSON: String, stream: Bool) -> [String: Any] {
        var input: [[String: Any]] = [["role": "user", "content": "Snapshot actual del sistema (contexto, no lo repitas):\n\(snapshotJSON)"]]
        for turn in history.suffix(12) { input.append(["role": turn.role, "content": turn.text]) }
        var body: [String: Any] = [
            "model": config.model,
            "instructions": instructions + "\nResponde en texto (markdown simple: negritas y listas), breve y accionable.",
            "input": input,
        ]
        if stream { body["stream"] = true }
        return body
    }

    public func chat(history: [AIChatTurn], snapshotJSON: String) async throws -> String {
        let body = chatBody(history: history, snapshotJSON: snapshotJSON, stream: false)
        return try await send(withReasoning(body), fallback: body)
    }

    /// Streams the answer token by token (Server-Sent Events from the Responses API).
    public func streamChat(history: [AIChatTurn], snapshotJSON: String) -> AsyncThrowingStream<String, Error> {
        let body = withReasoning(chatBody(history: history, snapshotJSON: snapshotJSON, stream: true))
        let plain = chatBody(history: history, snapshotJSON: snapshotJSON, stream: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await streamOnce(body, continuation)
                    } catch AIError.http(400, let message) where message.lowercased().contains("reasoning") {
                        try await streamOnce(plain, continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(_ body: [String: Any], _ continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let request = try makeRequest(path: "/responses", body: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte); if raw.count > 4000 { break } }
            throw AIError.http(status, Self.errorMessage(raw))
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "response.output_text.delta":
                if let delta = obj["delta"] as? String { continuation.yield(delta) }
            case "response.failed", "error":
                let message = ((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
                    ?? (obj["message"] as? String) ?? "error"
                throw AIError.badResponse(message)
            case "response.completed":
                OwnUsage.shared.record(purpose: purpose, model: config.model,
                                       tokens: OwnUsage.tokens(fromUsage: (obj["response"] as? [String: Any])?["usage"] as? [String: Any]))
                return
            default:
                continue
            }
        }
    }

    /// Validates the key and lists chat-capable models.
    public func listModels() async throws -> [String] {
        guard let url = URL(string: base + "/models") else { throw AIError.badResponse(L("URL inválida")) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIError.http(status, Self.errorMessage(data)) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let ids = ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        let excluded = ["audio", "realtime", "tts", "transcribe", "image", "embedding", "search", "moderation", "whisper", "dall-e", "davinci", "babbage", "instruct"]
        return ids.filter { id in
            (id.hasPrefix("gpt") || id.hasPrefix("o") || id.hasPrefix("chatgpt")) && !excluded.contains { id.contains($0) }
        }.sorted { a, b in
            func rank(_ id: String) -> Int { id.hasPrefix("gpt") ? 0 : id.hasPrefix("chatgpt") ? 2 : 1 }
            return rank(a) != rank(b) ? rank(a) < rank(b) : a.localizedStandardCompare(b) == .orderedDescending
        }
    }

    func makeRequest(path: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw AIError.badResponse(L("URL inválida")) }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func errorMessage(_ data: Data) -> String {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// Sends a request; if the model rejects the reasoning parameter, retries once without it.
    func send(_ body: [String: Any], fallback: [String: Any]) async throws -> String {
        do {
            return try await sendOnce(body)
        } catch AIError.http(400, let message) where message.lowercased().contains("reasoning") && body["reasoning"] != nil {
            return try await sendOnce(fallback)
        }
    }

    func sendOnce(_ body: [String: Any]) async throws -> String {
        let request = try makeRequest(path: "/responses", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIError.http(status, Self.errorMessage(data)) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        OwnUsage.shared.record(purpose: purpose, model: config.model, tokens: OwnUsage.tokens(fromUsage: obj?["usage"] as? [String: Any]))
        guard let output = obj?["output"] as? [[String: Any]] else { throw AIError.badResponse(L("sin 'output'")) }
        let texts = output
            .filter { ($0["type"] as? String) == "message" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { part -> String? in
                if let refusal = part["refusal"] as? String { return refusal }
                return (part["type"] as? String) == "output_text" ? part["text"] as? String : nil
            }
        guard !texts.isEmpty else { throw AIError.badResponse(L("sin texto")) }
        return texts.joined(separator: "\n")
    }
}
