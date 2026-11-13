import AppKit
import DevDeckCore
import SwiftUI

/// Real icons for apps and agents, taken from the applications installed on this Mac (nothing is bundled).
/// When there is no app to take it from (a project, a CLI-only agent, the system), callers fall back to a symbol.
@MainActor
enum BrandIcons {
    private static var cache: [String: NSImage?] = [:]

    /// Apps that represent an agent or a group whose own processes are not inside an app bundle.
    private static let aliases: [String: [String]] = [
        "Claude Code": ["Claude"], "Claude (app)": ["Claude"], "Codex": ["Codex", "ChatGPT"], "Gemini CLI": ["Gemini"],
        "OpenCode": ["OpenCode"], "Cursor Agent": ["Cursor"], "Docker": ["Docker"], "Chrome headless": ["Google Chrome", "Chromium"],
    ]

    private static let folders = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/Applications/Utilities"]

    private static func appPath(named name: String) -> String? {
        for folder in folders {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private static func image(atApp path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        let image: NSImage? = FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
        cache[path] = image
        return image
    }

    /// Icon for something known by name: an agent ("Claude Code"), an app ("Slack")…
    static func icon(named name: String) -> NSImage? {
        let key = "name:" + name
        if let cached = cache[key] { return cached }
        let names: [String] = [name] + (aliases[name] ?? [])
        var image: NSImage?
        for candidate in names {
            if let path = appPath(named: candidate) { image = self.image(atApp: path); break }
        }
        cache[key] = image
        return image
    }

    static func icon(for group: ProcessGroup, processes: [Int32: ProcessRecord]) -> NSImage? {
        switch group.kind {
        case .project, .system, .other: return nil
        default: break
        }
        let key = "group:" + group.id
        if let cached = cache[key] { return cached }
        var image = icon(named: group.name)
        if image == nil {
            // The outermost .app that holds one of its processes.
            for pid in group.pids.prefix(12) {
                guard let exe = processes[pid]?.executablePath, let range = exe.range(of: ".app/") else { continue }
                image = self.image(atApp: String(exe[..<range.lowerBound]) + ".app")
                if image != nil { break }
            }
        }
        cache[key] = image
        return image
    }
}

/// App or agent icon in the size of an `IconTile`; in colour or desaturated, as chosen in Settings.
struct BrandIconView: View {
    @Environment(AppModel.self) private var model
    let image: NSImage?
    let symbol: String
    var size: CGFloat = 24
    var active = false

    var body: some View {
        if let image, model.settings.iconStyle != "symbols" {
            let mono = model.settings.iconStyle == "mono"
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .saturation(mono ? 0 : 1)
                .opacity(mono ? 0.85 : 1)
        } else {
            IconTile(symbol: symbol, size: size, active: active)
        }
    }
}

/// Icon of a process group: the app's own icon when it has one, the kind's symbol otherwise.
struct GroupIcon: View {
    @Environment(AppModel.self) private var model
    let group: ProcessGroup
    var size: CGFloat = 26

    var body: some View {
        BrandIconView(image: BrandIcons.icon(for: group, processes: model.snapshot.processes), symbol: group.kind.symbol, size: size)
    }
}

/// Icon of an agent known only by its name (cards, accounts, usage).
struct AgentIcon: View {
    let name: String
    var size: CGFloat = 26
    var active = false

    var body: some View {
        BrandIconView(image: BrandIcons.icon(named: name), symbol: "terminal", size: size, active: active)
    }
}
