import DevDeckCore
import SwiftUI

/// Visual language: one neutral dark canvas, hairline borders, a single quiet accent.
/// Colour is reserved for meaning (warning, critical, success), never decoration.
enum Theme {
    static let background = Color(light: 0xF6F6F7, dark: 0x111113)
    static let sidebar = Color(light: 0xEDEDEF, dark: 0x161618)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1F)
    static let raised = Color(light: 0xE9E9EC, dark: 0x242428)

    /// Foreground "ink" at a given strength; flips with the appearance.
    static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    static let glassFill = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.75, darkAlpha: 0.035)
    static let glassStroke = Color.primary.opacity(0.09)
    static let secondaryText = Color.primary.opacity(0.58)
    static let tertiaryText = Color.primary.opacity(0.38)

    /// The one accent: a calm neutral used for data marks and selection.
    static let tint = Color(light: 0x3F3F46, dark: 0xD4D4D8)
    static let link = Color(light: 0x2563EB, dark: 0x8AB4F8)
    static let success = Color(light: 0x16A34A, dark: 0x4ADE80)
    static let warning = Color(light: 0xC27A0A, dark: 0xF5B94A)
    static let danger = Color(light: 0xD4403A, dark: 0xF2706B)

    static func colors(for section: SidebarSection) -> [Color] { [tint, surface, background] }
    static func accent(for section: SidebarSection) -> Color { tint }

    /// Colour by load: neutral until it matters.
    static func level(_ fraction: Double) -> Color {
        switch fraction {
        case 0.92...: return danger
        case 0.80...: return warning
        default: return tint
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// A colour that follows the window's light/dark appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    func lighter(_ amount: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return Color(.sRGB, red: min(1, ns.redComponent + amount), green: min(1, ns.greenComponent + amount),
                     blue: min(1, ns.blueComponent + amount), opacity: ns.alphaComponent)
    }
}

struct SectionBackground: View {
    let section: SidebarSection

    var body: some View {
        Theme.background.ignoresSafeArea()
    }
}

struct GlassModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var padding: CGFloat? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(Theme.glassFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.glassStroke, lineWidth: 1))
    }
}

extension View {
    /// A flat surface with a hairline border.
    func glass(cornerRadius: CGFloat = 10, padding: CGFloat? = nil) -> some View {
        modifier(GlassModifier(cornerRadius: min(cornerRadius, 12), padding: padding))
    }
}

/// Titled surface (replaces GroupBox).
struct Panel<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, symbol: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Theme.tertiaryText)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 12)
    }
}

/// Page title: plain, left-aligned, no ornaments.
struct HeroHeader<Trailing: View>: View {
    let section: SidebarSection
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            trailing()
        }
        .padding(.bottom, 2)
    }
}

extension HeroHeader where Trailing == EmptyView {
    init(section: SidebarSection, title: String, subtitle: String) {
        self.init(section: section, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Thin monochrome ring; turns amber/red only when the value is high.
struct RingGauge<Center: View>: View {
    let value: Double
    var lineWidth: CGFloat = 6
    /// Kept for source compatibility; rings are monochrome by design.
    var colors: [Color] = []
    var semantic = true
    @ViewBuilder var center: () -> Center

    var body: some View {
        let stroke = min(lineWidth, 8)
        ZStack {
            Circle().stroke(Theme.ink(0.08), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: min(max(value, 0.001), 1))
                .stroke(semantic ? Theme.level(value) : Theme.tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: value)
            center()
        }
    }
}

struct MetricRing: View {
    let title: String
    let value: Double
    let text: String
    var subtitle: String = ""
    var size: CGFloat = 92
    var colors: [Color] = []
    var semantic = true

    var body: some View {
        VStack(spacing: 8) {
            RingGauge(value: value, lineWidth: 5, semantic: semantic) {
                Text(text)
                    .font(.system(size: size * 0.19, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, size * 0.14)
            }
            .frame(width: size, height: size)
            VStack(spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText).lineLimit(1)
                }
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Theme.background : Theme.ink(0.92))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Theme.ink(configuration.isPressed ? 0.8 : 0.94)
                                    : Theme.ink(configuration.isPressed ? 0.14 : 0.08))
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.ink(prominent ? 0 : 0.10), lineWidth: 1))
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(prominent: Bool, tint: Color = .primary) -> PillButtonStyle { PillButtonStyle(prominent: prominent, tint: tint) }
}

/// Keycap like ⌘K / ↵.
struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.ink(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The DevDeck mark: a monochrome gauge.
struct AppGlyph: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Theme.raised)
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Theme.ink(0.10), lineWidth: 1)
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(Theme.ink(0.9), style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(90))
                .frame(width: size * 0.56, height: size * 0.56)
            Capsule().fill(Color.primary)
                .frame(width: size * 0.05, height: size * 0.22)
                .offset(y: -size * 0.09)
                .rotationEffect(.degrees(38))
        }
        .frame(width: size, height: size)
    }
}

/// Small monochrome icon tile used in lists and the sidebar.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 24
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(active ? Color.primary : Theme.secondaryText)
            .frame(width: size, height: size)
            .background(Theme.ink(active ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

extension View {
    /// Floating surfaces (palette, island, banners): real Liquid Glass on macOS 26, material before that.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // The glass API only exists in the macOS 26 SDK (Xcode 26); older toolchains build the material version.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.background(Theme.surface.opacity(0.55), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 1))
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 1))
        #endif
    }

    /// Light / dark / follow the system, from Settings.
    /// Rebuilds the view tree when the language changes, so every `L(…)` is evaluated again.
    func appLanguage(_ language: AppLanguage) -> some View {
        environment(\.locale, language.locale).id(language)
    }

    func appAppearance(_ mode: String) -> some View {
        preferredColorScheme(mode == "light" ? .light : mode == "dark" ? .dark : nil)
    }
}
