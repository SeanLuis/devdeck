import AppKit
import Carbon.HIToolbox
import DevDeckCore
import SwiftUI

struct IslandAlert: Equatable {
    let id = UUID()
    let title: String
    let message: String
    let severity: AlertSeverity
}

/// A live status pill at the top-centre of the screen (Dynamic-Island style). Compact by default; it expands with
/// alerts and with the copilot, and a click opens the boards (system, agents, accounts, copilot).
/// It can be always there, only while something needs attention, or off.
@MainActor
final class IslandController {
    static let shared = IslandController()
    static let size = NSSize(width: 580, height: 600)
    private var panel: NSPanel?
    private var placedOn: NSRect = .zero

    /// Whether the island should be on screen right now.
    func wanted(_ model: AppModel) -> Bool {
        guard !model.headless else { return false }
        switch model.settings.islandMode {
        case "always": return true
        case "auto": return model.islandAlert != nil || model.copilotOnIsland || model.deckOpen
        default: return false
        }
    }

    func update(model: AppModel) {
        if wanted(model) {
            show(model: model)
        } else if panel?.isVisible == true {
            model.deckOpen = false
            panel?.orderOut(nil)
        }
    }

    private func show(model: AppModel) {
        let size = Self.size
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: IslandView().environment(model))
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        // Only move the window when the screen changed: this runs on every sample.
        if placedOn != screen.frame || !panel.isVisible {
            placedOn = screen.frame
            // On MacBooks with a notch the island grows out of the notch itself; elsewhere it sits under the menu bar.
            let barHeight = screen.safeAreaInsets.top
            if barHeight > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                model.notchWidth = screen.frame.width - left.width - right.width
                model.notchHeight = barHeight
                panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            } else {
                model.notchWidth = 0
                panel.level = .statusBar
                panel.appearance = nil
                panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 4, width: size.width, height: size.height), display: true)
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

/// The island itself: a compact header (in the notch's wings, or a pill), and under it whichever of these applies:
/// an alert, the open boards, or a short peek while the pointer is over it.
struct IslandView: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var notch: Bool { model.notchWidth > 0 }

    var body: some View {
        let alert = model.islandAlert
        let open = model.deckOpen
        let copilot = model.copilotOnIsland
        let expanded = open || alert != nil || hovering || copilot
        let radius: CGFloat = open ? 22 : expanded ? 18 : (notch ? 12 : 15)
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if open {
                    DeckView(notch: notch)
                        .transition(.opacity)
                } else if let alert {
                    alertRow(alert).transition(.opacity)
                } else if copilot {
                    CopilotStrip().transition(.opacity)
                } else if hovering {
                    peek.transition(.opacity)
                }
            }
            .frame(width: width(open: open, expanded: expanded))
            .foregroundStyle(notch ? Color.white : Color.primary)
            .modifier(IslandSurface(notch: notch, radius: radius))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.36, bounce: 0.16), value: open)
            .animation(.spring(duration: 0.36, bounce: 0.16), value: expanded)
            .animation(.spring(duration: 0.36, bounce: 0.16), value: alert)
            Spacer(minLength: 0)
        }
        .frame(width: IslandController.size.width, height: IslandController.size.height, alignment: .top)
        .appAppearance(notch ? "dark" : model.settings.appearance)
        .appLanguage(model.settings.language)
    }

    private func width(open: Bool, expanded: Bool) -> CGFloat? {
        if open { return 540 }
        if notch { return model.notchWidth + (expanded ? 240 : 156) }
        return expanded ? 380 : nil
    }

    private func toggleDeck() {
        if model.islandAlert != nil { model.islandAlert = nil }
        if !model.deckOpen {
            // Open on whatever needs attention; otherwise on the user's default board.
            model.deckTab = model.copilotOnIsland ? DeckTab.copilot.rawValue : model.settings.deckTab
            Task { await model.refreshLiveSessions() }
        }
        model.deckOpen.toggle()
        IslandController.shared.update(model: model)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        let s = model.system
        Group {
            if notch {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.pressure(s.pressure)).frame(width: 6, height: 6)
                        Text("\(Int(s.memPercent))%").font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(width: model.notchWidth)
                    HStack(spacing: 4) {
                        if model.agentRunning || model.aiBusy {
                            ProgressView().controlSize(.mini).scaleEffect(0.7)
                        } else if !model.pendingApprovals.isEmpty {
                            Image(systemName: "hand.raised.fill").font(.system(size: 9)).foregroundStyle(Theme.warning)
                        } else {
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .semibold)).opacity(0.6)
                        }
                        Text(model.pendingApprovals.isEmpty || model.agentRunning ? Self.short(s.swapUsed) : "\(model.pendingApprovals.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(height: model.notchHeight)
            } else {
                HStack(spacing: 10) {
                    Circle().fill(Color.pressure(s.pressure)).frame(width: 7, height: 7)
                    Text("RAM \(Int(s.memPercent))%").font(.system(size: 12, weight: .medium).monospacedDigit())
                    Text("Swap \(Fmt.bytes(s.swapUsed))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    if model.agentRunning || model.aiBusy {
                        ProgressView().controlSize(.mini)
                        Text(L("Copiloto")).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    } else if !model.pendingApprovals.isEmpty {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(Theme.warning)
                        Text("\(model.pendingApprovals.count)").font(.system(size: 12).monospacedDigit())
                    } else if agents > 0 {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                        Text("\(agents)").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                    if model.deckOpen || hovering { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleDeck() }
        .help(L("Clic para abrir los tableros"))
    }

    private var agents: Int { model.snapshot.groups.filter { $0.kind == .agent }.count }

    private func alertRow(_ alert: IslandAlert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.severity == .critical ? "exclamationmark.octagon.fill" : alert.severity == .warning ? "exclamationmark.triangle.fill" : "bell.fill")
                .foregroundStyle(Color.severity(alert.severity))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.system(size: 13, weight: .semibold))
                Text(alert.message).font(.system(size: 12)).opacity(0.7).lineLimit(3)
            }
            Spacer(minLength: 0)
            Button { model.islandAlert = nil; IslandController.shared.update(model: model) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).opacity(0.6).help(L("Cerrar"))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { model.islandAlert = nil; Notifier.shared.onOpen?(.rules) }
    }

    private var peek: some View {
        VStack(spacing: 5) {
            ForEach(model.snapshot.groups.prefix(3)) { group in
                HStack(spacing: 8) {
                    GroupIcon(group: group, size: 16)
                    Text(group.name).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(Fmt.bytes(group.memoryBytes)).font(.system(size: 12).monospacedDigit()).opacity(0.7)
                }
            }
            Text(L("Clic para abrir los tableros")).font(.system(size: 10)).opacity(0.45).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture { toggleDeck() }
    }

    static func short(_ bytes: UInt64) -> String {
        let gb = Fmt.gb(bytes)
        return gb >= 1 ? String(format: "%.1fG", gb) : "\(Int(Fmt.mb(bytes)))M"
    }
}

/// Black and flush with the top edge when it hangs from the notch; floating glass otherwise.
struct IslandSurface: ViewModifier {
    let notch: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if notch {
            content.background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous))
        } else {
            // Solid surface: the boards hold charts and controls that must stay readable over any wallpaper.
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .background(Theme.surface.opacity(0.97), in: shape)
                .overlay(shape.strokeBorder(Theme.ink(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
    }
}

/// Records a global shortcut (key + modifiers).
struct HotKeyRecorder: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Pulsa la combinación…") : model.settings.hotKeyLabel)
                .font(.system(size: 13, weight: .medium, design: recording ? .default : .monospaced))
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stop(); return nil }   // esc cancels
            guard !flags.isEmpty, flags != .shift else { return nil }
            var carbon = 0, label = ""
            if flags.contains(.control) { carbon |= controlKey; label += "⌃" }
            if flags.contains(.option) { carbon |= optionKey; label += "⌥" }
            if flags.contains(.shift) { carbon |= shiftKey; label += "⇧" }
            if flags.contains(.command) { carbon |= cmdKey; label += "⌘" }
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "?").uppercased()
            model.settings.hotKeyCode = Int(event.keyCode)
            model.settings.hotKeyModifiers = carbon
            model.settings.hotKeyLabel = label + key
            model.saveSettings()
            model.applyHotKey()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
