import AppKit
import Carbon.HIToolbox
import DevDeckCore
import SwiftUI

/// A panel that can take keyboard focus without a title bar.
final class KeyPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        close()
    }
    override func close() {
        orderOut(nil)
        onClose?()
    }
}

// MARK: - Global hotkey

enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false
    private static var nextID: UInt32 = 1

    /// Replaces every registered shortcut with this one (the launcher shortcut is user-configurable).
    static func set(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
        register(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }

    static func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandler()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4456_4B59), id: id)   // "DVKY"
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Command palette window

@MainActor
final class PaletteController {
    static let shared = PaletteController()
    weak var model: AppModel?
    private var panel: KeyPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? panel?.close() : show() }

    func show() {
        guard let model else { return }
        if panel == nil {
            let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                                 styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: CommandPaletteView(floating: true)
                .environment(model)
                .appAppearance(model.settings.appearance))
            self.panel = panel
        }
        guard let panel else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - frame.height * 0.16))
        }
        model.paletteToken = UUID()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.close() }
}

// MARK: - DevDeck's own notification banner

@MainActor
final class BannerCenter {
    static let shared = BannerCenter()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(title: String, body: String, severity: AlertSeverity, onClick: @escaping () -> Void) {
        let size = NSSize(width: 360, height: 92)
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = p
            return p
        }()
        panel.contentView = NSHostingView(rootView: BannerView(title: title, message: body, severity: severity) { [weak self] in
            onClick()
            self?.dismiss()
        } onClose: { [weak self] in self?.dismiss() })
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(NSRect(x: frame.maxX - size.width - 14, y: frame.maxY - size.height - 10, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    func dismiss() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
    }
}

struct BannerView: View {
    let title: String
    let message: String
    let severity: AlertSeverity
    let onClick: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink(0.08))
                Image(systemName: severity == .critical ? "exclamationmark.octagon.fill" : severity == .warning ? "exclamationmark.triangle.fill" : "bell.fill")
                    .foregroundStyle(Color.severity(severity))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(.callout).weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                }
                Text(message).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
            }
        }
        .padding(14)
        .frame(width: 360, height: 92, alignment: .topLeading)
        .floatingGlass(cornerRadius: 14)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}
