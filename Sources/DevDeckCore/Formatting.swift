import Foundation

public enum Fmt {
    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    public static func mb(_ value: UInt64) -> Double { Double(value) / 1_048_576 }
    public static func gb(_ value: UInt64) -> Double { Double(value) / 1_073_741_824 }

    public static func percent(_ value: Double) -> String {
        value >= 10 || value == 0 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    public static func duration(since date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \(s % 3600 / 60)m"
        default: return "\(s / 86400)d \(s % 86400 / 3600)h"
        }
    }

    /// `/Users/me/x` → `~/x`
    public static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Short human command: paths collapsed to their last component.
    public static func shortCommand(_ args: [String], max: Int = 4) -> String {
        args.prefix(max).map { arg in
            arg.hasPrefix("/") ? (arg as NSString).lastPathComponent : arg
        }.joined(separator: " ")
    }
}
