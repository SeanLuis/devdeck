import DevDeckCore
import SwiftUI

extension Color {
    static func pressure(_ level: Int) -> Color {
        switch level {
        case 4...: return Theme.danger
        case 2...: return Theme.warning
        default: return Theme.success
        }
    }

    static func usage(_ fraction: Double) -> Color { Theme.level(fraction) }

    /// Kinds are told apart by their symbol, not by colour.
    static func kind(_ kind: GroupKind) -> Color { Theme.tint }

    static func severity(_ s: AlertSeverity) -> Color {
        switch s {
        case .critical: return Theme.danger
        case .warning: return Theme.warning
        case .info: return Theme.secondaryText
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var tint: Color = .accentColor
    var fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(tint)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .glass(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(fraction.map { $0 > 0.75 ? 0.7 : 0 } ?? 0), lineWidth: 1.5))
    }
}

struct KindIcon: View {
    let kind: GroupKind
    var size: CGFloat = 26

    var body: some View { IconTile(symbol: kind.symbol, size: size) }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct UsageBar: View {
    let fraction: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink(0.10))
                Capsule().fill(tint).frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct EmptyHint: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Theme.tertiaryText)
            Text(title).font(.system(.headline))
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

/// Floating status message at the bottom of the window.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.raised))
                .overlay(Capsule().strokeBorder(Theme.ink(0.16)))
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
        }
    }
}

/// Kill button with a confirmation dialog.
struct KillButton: View {
    let title: String
    let message: String
    var label: String = L("Cerrar")
    var compact = false
    let action: () async -> Void
    @State private var confirming = false
    @State private var running = false

    var body: some View {
        Button(role: .destructive) {
            confirming = true
        } label: {
            if running {
                ProgressView().controlSize(.small)
            } else if compact {
                Image(systemName: "xmark.circle.fill")
            } else {
                Label(label, systemImage: "xmark.circle")
            }
        }
        .help(title)
        .disabled(running)
        .confirmationDialog(title, isPresented: $confirming) {
            Button(label, role: .destructive) {
                running = true
                Task {
                    await action()
                    running = false
                }
            }
        } message: {
            Text(message)
        }
    }
}

func uptime(_ date: Date) -> String { Fmt.duration(since: date) }
