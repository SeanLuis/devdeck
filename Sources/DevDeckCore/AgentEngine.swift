import Foundation

/// Which brain answers the copilot.
public enum AIProvider: String, Codable, CaseIterable, Sendable {
    case claudeCode, codex, openAI

    public var title: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openAI: return "OpenAI API"
        }
    }

    public var detail: String {
        switch self {
        case .claudeCode: return L("Usa tu sesión de Claude Code. Sin API key.")
        case .codex: return L("Usa tu sesión de Codex. Sin API key.")
        case .openAI: return L("Llama a la API con tu propia key.")
        }
    }

    public var binary: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .openAI: return nil
        }
    }
}

/// Common interface for every backend (local agent CLIs or an HTTP API).
public protocol AIBackend: Sendable {
    func diagnose(snapshotJSON: String, focus: String?) async throws -> AIDiagnosis
    func streamChat(history: [AIChatTurn], snapshotJSON: String) -> AsyncThrowingStream<String, Error>
    /// One structured response following a JSON schema (used by the agent loop).
    func structured(instructions: String, prompt: String, schemaJSON: String) async throws -> Data
}

extension OpenAIClient: AIBackend {}

public enum AgentEngineError: LocalizedError {
    case notInstalled(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name): return L("No encuentro '%@' instalado. Elige otro motor en Ajustes → IA.", name)
        case .failed(let message): return message
        }
    }
}

/// Runs the locally installed agent CLI headless, with no tools, as the copilot's model.
/// Same idea as editors that embed Claude Code / Codex: the user's own login, no key stored in the app.
public struct AgentCLIBackend: AIBackend {
    public let provider: AIProvider
    public let binaryPath: String
    public let model: String?
    public let instructions: String
    public let environment: [String: String]
    public let workingDirectory: URL
    /// What the call is for, for DevDeck's own usage ledger: "copilot" or "automatic".
    public var purpose = "copilot"

    private func record(_ usage: [String: Any]?) {
        OwnUsage.shared.record(purpose: purpose, model: "\(provider.title) · \(model ?? "default")", tokens: OwnUsage.tokens(fromUsage: usage))
    }

    public init(provider: AIProvider, binaryPath: String, model: String?, instructions: String,
                environment: [String: String], workingDirectory: URL) {
        self.provider = provider
        self.binaryPath = binaryPath
        self.model = (model?.isEmpty ?? true) || model == "default" ? nil : model
        self.instructions = instructions
        var env = environment
        // Never let a parent agent session leak into the child CLI.
        for key in env.keys where key.hasPrefix("CLAUDECODE") || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CODEX_") { env[key] = nil }
        self.environment = env
        self.workingDirectory = workingDirectory
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    static let schemaJSON: String = {
        let data = (try? JSONSerialization.data(withJSONObject: OpenAIClient.diagnosisSchema, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    // MARK: Diagnose

    public func diagnose(snapshotJSON: String, focus: String?) async throws -> AIDiagnosis {
        var prompt = "Snapshot del sistema:\n\(snapshotJSON)\n\n"
        prompt += focus.map { "Pregunta concreta del usuario: \($0)" } ?? "Diagnostica el estado actual y propone acciones si hacen falta."
        switch provider {
        case .claudeCode:
            var args = ["-p", prompt, "--output-format", "json", "--json-schema", Self.schemaJSON, "--system-prompt", instructions]
            args += claudeSafetyArgs
            let result = try await run(args)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else {
                throw AgentEngineError.failed(L("Claude Code devolvió una respuesta no válida: %@", String(result.prefix(200))))
            }
            record(obj["usage"] as? [String: Any])
            if (obj["is_error"] as? Bool) == true { throw AgentEngineError.failed((obj["result"] as? String) ?? L("Claude Code falló")) }
            if let structured = obj["structured_output"], let data = try? JSONSerialization.data(withJSONObject: structured) {
                return try JSONDecoder().decode(AIDiagnosis.self, from: data)
            }
            return try decodeLoose((obj["result"] as? String) ?? "")
        case .codex:
            let schemaURL = workingDirectory.appendingPathComponent("diagnosis-schema.json")
            try Self.schemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)
            let args = codexArgs + ["--output-schema", schemaURL.path, instructions + "\n\n" + prompt]
            return try decodeLoose(codexMessage(from: try await run(args)))
        case .openAI:
            throw AgentEngineError.failed(L("Motor incorrecto"))
        }
    }

    public func structured(instructions: String, prompt: String, schemaJSON: String) async throws -> Data {
        switch provider {
        case .claudeCode:
            let args = ["-p", prompt, "--output-format", "json", "--json-schema", schemaJSON, "--system-prompt", instructions] + claudeSafetyArgs
            let result = try await run(args)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] else {
                throw AgentEngineError.failed(L("Claude Code devolvió una respuesta no válida"))
            }
            record(obj["usage"] as? [String: Any])
            if (obj["is_error"] as? Bool) == true { throw AgentEngineError.failed((obj["result"] as? String) ?? L("Claude Code falló")) }
            if let structured = obj["structured_output"], let data = try? JSONSerialization.data(withJSONObject: structured) { return data }
            return Data(Self.jsonBody((obj["result"] as? String) ?? "").utf8)
        case .codex:
            let schemaURL = workingDirectory.appendingPathComponent("step-schema.json")
            try schemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)
            let output = try await run(codexArgs + ["--output-schema", schemaURL.path, instructions + "\n\n" + prompt])
            return Data(Self.jsonBody(codexMessage(from: output)).utf8)
        case .openAI:
            throw AgentEngineError.failed(L("Motor incorrecto"))
        }
    }

    static func jsonBody(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return text }
        return String(text[start...end])
    }

    private func decodeLoose(_ text: String) throws -> AIDiagnosis {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") { body = String(body[start...end]) }
        do { return try JSONDecoder().decode(AIDiagnosis.self, from: Data(body.utf8)) }
        catch { throw AgentEngineError.failed(L("No pude interpretar la respuesta de %@: %@", provider.title, String(text.prefix(160)))) }
    }

    // MARK: Chat

    public func streamChat(history: [AIChatTurn], snapshotJSON: String) -> AsyncThrowingStream<String, Error> {
        var prompt = "Snapshot actual del sistema (contexto, no lo repitas):\n\(snapshotJSON)\n\n"
        for turn in history.suffix(12) { prompt += (turn.role == "user" ? "Usuario: " : "Asistente: ") + turn.text + "\n\n" }
        prompt += "Responde al último mensaje del usuario en texto (markdown simple), breve y accionable."
        let finalPrompt = prompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch provider {
                    case .claudeCode:
                        let args = ["-p", finalPrompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                                    "--system-prompt", instructions] + claudeSafetyArgs
                        var sawDelta = false
                        try await stream(args) { line in
                            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
                            switch obj["type"] as? String {
                            case "stream_event":
                                if let event = obj["event"] as? [String: Any], (event["type"] as? String) == "content_block_delta",
                                   let delta = event["delta"] as? [String: Any], let text = delta["text"] as? String {
                                    sawDelta = true
                                    continuation.yield(text)
                                }
                            case "result":
                                record(obj["usage"] as? [String: Any])
                                if (obj["is_error"] as? Bool) == true {
                                    continuation.yield("\n⚠️ " + ((obj["result"] as? String) ?? L("Claude Code falló")))
                                } else if !sawDelta, let text = obj["result"] as? String {
                                    continuation.yield(text)
                                }
                            default: break
                            }
                        }
                    case .codex:
                        let output = try await run(codexArgs + [instructions + "\n\n" + finalPrompt])
                        continuation.yield(codexMessage(from: output))
                    case .openAI:
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: CLI plumbing

    /// No tools, no MCP servers, no user hooks/plugins, nothing written to the session history.
    private var claudeSafetyArgs: [String] {
        var args = ["--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", ""]
        if let model { args += ["--model", model] }
        return args
    }

    private var codexArgs: [String] {
        var args = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "-s", "read-only", "--color", "never"]
        if let model { args += ["-m", model] }
        return args
    }

    /// Last `agent_message` of a `codex exec --json` run.
    private func codexMessage(from output: String) -> String {
        var message = ""
        var failure: String?
        for line in output.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let item = obj["item"] as? [String: Any], (item["type"] as? String) == "agent_message", let text = item["text"] as? String {
                message = text
            }
            if (obj["type"] as? String) == "turn.completed" { record(obj["usage"] as? [String: Any]) }
            if (obj["type"] as? String) == "turn.failed" || (obj["type"] as? String) == "error" {
                failure = ((obj["error"] as? [String: Any])?["message"] as? String) ?? (obj["message"] as? String)
            }
        }
        return message.isEmpty ? "⚠️ " + (failure ?? L("Codex no devolvió respuesta")) : message
    }

    private func makeProcess(_ args: [String]) -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        return (process, out, err)
    }

    private func run(_ args: [String], timeout: TimeInterval = 180) async throws -> String {
        let result = await Shell.run(binaryPath, args, cwd: workingDirectory.path, env: environment, timeout: timeout)
        if result.timedOut { throw AgentEngineError.failed(L("%@ tardó demasiado en responder", provider.title)) }
        if result.stdout.isEmpty && result.status != 0 {
            throw AgentEngineError.failed(L("%@ falló (%@): %@", provider.title, "\(result.status)", String(result.stderr.suffix(300))))
        }
        return result.stdout
    }

    private func stream(_ args: [String], onLine: (String) -> Void) async throws {
        let (process, out, err) = makeProcess(args)
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await withTaskCancellationHandler {
            for try await line in out.fileHandleForReading.bytes.lines { onLine(line) }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
            if !message.isEmpty { throw AgentEngineError.failed(L("%@ falló: %@", provider.title, String(message.suffix(300)))) }
        }
    }
}

public enum AIEngine {
    /// Providers that can work right now on this machine.
    public static func available(env: [String: String], store: JSONStore, config: AIConfig) -> [AIProvider] {
        AIProvider.allCases.filter { provider in
            if let binary = provider.binary { return LoginEnvironment.which(binary, env: env) != nil }
            return AIKeyProvider.key(config: config, store: store) != nil
        }
    }

    public static func backend(config: AIConfig, store: JSONStore, env: [String: String], purpose: String = "copilot") throws -> AIBackend {
        let instructions = OpenAIClient(config: config, apiKey: "").instructions
        switch config.provider {
        case .openAI:
            guard let key = AIKeyProvider.key(config: config, store: store) else { throw AIError.missingKey }
            var client = OpenAIClient(config: config, apiKey: key)
            client.purpose = purpose
            return client
        case .claudeCode, .codex:
            let name = config.provider.binary ?? ""
            guard let path = LoginEnvironment.which(name, env: env) else { throw AgentEngineError.notInstalled(name) }
            var backend = AgentCLIBackend(provider: config.provider, binaryPath: path,
                                          model: config.provider == .claudeCode ? config.claudeModel : config.codexModel,
                                          instructions: instructions, environment: env,
                                          workingDirectory: store.directory.appendingPathComponent("agent-cwd", isDirectory: true))
            backend.purpose = purpose
            return backend
        }
    }
}
