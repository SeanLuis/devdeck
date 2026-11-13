import AppKit
import SwiftUI

/// DevDeck's mark: a solid "D" whose counter is a gauge needle. One shape, one colour.
struct LogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let h = rect.height, w = rect.width
        let radius = h / 2
        var d = Path()
        d.move(to: CGPoint(x: rect.minX, y: rect.minY))
        d.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        d.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        d.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        d.closeSubpath()

        // The needle: a slot from the pivot towards the upper right, cut out of the D.
        let pivot = CGPoint(x: rect.minX + w * 0.36, y: rect.minY + h * 0.64)
        let length = h * 0.62, thickness = h * 0.135
        var needle = Path(roundedRect: CGRect(x: 0, y: -thickness / 2, width: length, height: thickness), cornerRadius: thickness / 2)
        needle = needle.applying(CGAffineTransform(rotationAngle: -.pi * 0.27)).applying(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        return d.subtracting(needle)
    }
}

/// The app icon: the mark in white on black, on the macOS icon grid.
struct LogoArt: View {
    var game = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.11), .black], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 3)
                .frame(width: 824, height: 824)
            if game {
                Image(systemName: "gamecontroller.fill").font(.system(size: 400, weight: .regular)).foregroundStyle(.white)
            } else {
                LogoMark().fill(.white).frame(width: 400, height: 440).offset(x: 14)
            }
        }
        .frame(width: 1024, height: 1024)
    }

    @MainActor
    static func image(game: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: LogoArt(game: game))
        renderer.scale = 0.5
        return renderer.nsImage
    }
}
