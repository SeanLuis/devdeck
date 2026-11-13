import Foundation

/// What a process is for, in words a person recognizes: "Pestaña o extensión", "GPU", "Servicio de red"…
/// Browsers and Electron apps run dozens of helpers with the same name; their command line says which is which.
public struct ProcessRole: Hashable, Sendable {
    /// Stable key to group by.
    public let key: String
    /// Spanish source text (translated at display, like every other string).
    public let title: String
    /// One line saying what it does.
    public let detail: String

    public init(key: String, title: String, detail: String) {
        self.key = key; self.title = title; self.detail = detail
    }

    static func flag(_ name: String, in args: [String]) -> String? {
        let prefix = "--\(name)="
        for arg in args where arg.hasPrefix(prefix) { return String(arg.dropFirst(prefix.count)) }
        return nil
    }

    /// Role of a process inside its app, or nil when its own name already says it all.
    public static func of(name: String, executablePath: String, args: [String]) -> ProcessRole? {
        let lowerName = name.lowercased()
        let isHelper = lowerName.contains("helper") || executablePath.contains("/Frameworks/") || executablePath.contains(".framework/")

        // Chromium (Chrome, Brave, Edge, Arc…) and Electron (VS Code, Cursor, Slack, Claude…).
        if let type = flag("type", in: args) {
            switch type {
            case "renderer":
                if args.contains("--extension-process") {
                    return ProcessRole(key: "extension", title: "Extensión", detail: "Código de una extensión del navegador")
                }
                return ProcessRole(key: "renderer", title: "Pestaña o ventana", detail: "Dibuja y ejecuta una página; cada pestaña abierta tiene el suyo")
            case "gpu-process":
                return ProcessRole(key: "gpu", title: "Gráficos (GPU)", detail: "Dibuja en pantalla todas las ventanas de la app")
            case "utility":
                let sub = (flag("utility-sub-type", in: args) ?? "").lowercased()
                if sub.contains("network") { return ProcessRole(key: "network", title: "Red", detail: "Todas las conexiones y descargas de la app") }
                if sub.contains("audio") { return ProcessRole(key: "audio", title: "Audio", detail: "Sonido de las pestañas") }
                if sub.contains("storage") { return ProcessRole(key: "storage", title: "Almacenamiento", detail: "Cookies, caché y datos de sitios") }
                if sub.contains("video_capture") || sub.contains("videocapture") { return ProcessRole(key: "camera", title: "Cámara", detail: "Captura de vídeo") }
                if sub.contains("node") { return ProcessRole(key: "node", title: "Proceso Node", detail: "Extensiones o tareas en segundo plano de la app") }
                if sub.contains("tracing") { return ProcessRole(key: "tracing", title: "Diagnóstico", detail: "Recoge trazas de rendimiento") }
                return ProcessRole(key: "utility", title: "Servicio auxiliar", detail: sub.isEmpty ? "Tarea interna de la app" : sub)
            case "crashpad-handler":
                return ProcessRole(key: "crash", title: "Informes de fallos", detail: "Espera por si la app se cierra de forma inesperada")
            case "zygote", "broker":
                return ProcessRole(key: "zygote", title: "Arranque de procesos", detail: "Plantilla para crear procesos nuevos rápido")
            case "ppapi", "plugin":
                return ProcessRole(key: "plugin", title: "Complemento", detail: "Complemento de la app")
            default:
                return ProcessRole(key: "type-" + type, title: "Auxiliar", detail: type)
            }
        }
        if lowerName.contains("crashpad") { return ProcessRole(key: "crash", title: "Informes de fallos", detail: "Espera por si la app se cierra de forma inesperada") }
        if lowerName.hasSuffix("(gpu)") { return ProcessRole(key: "gpu", title: "Gráficos (GPU)", detail: "Dibuja en pantalla todas las ventanas de la app") }
        if lowerName.hasSuffix("(renderer)") { return ProcessRole(key: "renderer", title: "Pestaña o ventana", detail: "Dibuja y ejecuta una página; cada pestaña abierta tiene el suyo") }
        if lowerName.hasSuffix("(plugin)") { return ProcessRole(key: "plugin", title: "Complemento", detail: "Complemento de la app") }

        // Safari / WebKit.
        if lowerName.contains("com.apple.webkit.webcontent") || lowerName == "safari web content" {
            return ProcessRole(key: "renderer", title: "Pestaña o ventana", detail: "Dibuja y ejecuta una página; cada pestaña abierta tiene el suyo")
        }
        if lowerName.contains("com.apple.webkit.networking") { return ProcessRole(key: "network", title: "Red", detail: "Todas las conexiones y descargas de la app") }
        if lowerName.contains("com.apple.webkit.gpu") { return ProcessRole(key: "gpu", title: "Gráficos (GPU)", detail: "Dibuja en pantalla todas las ventanas de la app") }

        // Developer tooling that hides behind "node" / "java".
        let joined = args.prefix(8).joined(separator: " ").lowercased()
        if joined.contains("tsserver") { return ProcessRole(key: "tsserver", title: "Servidor de TypeScript", detail: "Autocompletado y errores del editor") }
        if joined.contains("eslint") { return ProcessRole(key: "eslint", title: "ESLint", detail: "Revisión de código del editor") }
        if joined.contains("language-server") || joined.contains("languageserver") || joined.contains("lsp") {
            return ProcessRole(key: "lsp", title: "Servidor de lenguaje", detail: "Autocompletado y errores del editor")
        }
        if joined.contains("gradledaemon") { return ProcessRole(key: "gradle", title: "Daemon de Gradle", detail: "Queda vivo entre compilaciones; se puede cerrar") }
        if joined.contains("kotlincompiledaemon") { return ProcessRole(key: "kotlin", title: "Daemon de Kotlin", detail: "Compilador en segundo plano; se puede cerrar") }
        if Classifier.isMCPServer(args) { return ProcessRole(key: "mcp", title: "Servidor MCP", detail: "Herramientas que usa un agente de IA") }
        if isHelper { return ProcessRole(key: "helper", title: "Auxiliar", detail: "Proceso interno de la app") }
        return nil
    }

    /// Every role title and detail, for the translation tables.
    public static var displayStrings: [String] {
        ["Extensión", "Código de una extensión del navegador", "Pestaña o ventana", "Dibuja y ejecuta una página; cada pestaña abierta tiene el suyo",
         "Gráficos (GPU)", "Dibuja en pantalla todas las ventanas de la app", "Red", "Todas las conexiones y descargas de la app", "Audio",
         "Sonido de las pestañas", "Almacenamiento", "Cookies, caché y datos de sitios", "Cámara", "Captura de vídeo", "Proceso Node",
         "Extensiones o tareas en segundo plano de la app", "Diagnóstico", "Recoge trazas de rendimiento", "Servicio auxiliar", "Tarea interna de la app",
         "Informes de fallos", "Espera por si la app se cierra de forma inesperada", "Arranque de procesos", "Plantilla para crear procesos nuevos rápido",
         "Complemento", "Complemento de la app", "Auxiliar", "Servidor de TypeScript", "Autocompletado y errores del editor", "ESLint",
         "Revisión de código del editor", "Servidor de lenguaje", "Daemon de Gradle", "Queda vivo entre compilaciones; se puede cerrar",
         "Daemon de Kotlin", "Compilador en segundo plano; se puede cerrar", "Servidor MCP", "Herramientas que usa un agente de IA", "Proceso interno de la app",
         "Aplicación principal", "La ventana y el control de todo lo demás"]
    }
}
