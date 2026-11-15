import Foundation

/// Which saved account a folder's agent work belongs to (a client's plan, the personal one…).
/// The agent's login is one for the whole Mac, so this decides which account is put in place before the agent
/// is opened there, and tells when a session started under a different one.
public enum FolderAccounts {
    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// The account assigned to `folder` or to the closest folder above it.
    public static func account(for folder: String, in assigned: [String: String]) -> String? {
        let target = normalized(folder)
        var best: (length: Int, id: String)?
        for (root, id) in assigned {
            let base = normalized(root)
            guard target == base || target.hasPrefix(base == "/" ? "/" : base + "/") else { continue }
            if base.count > (best?.length ?? -1) { best = (base.count, id) }
        }
        return best?.id
    }

    /// The folder whose assignment applies to `folder` (itself or one above).
    public static func assignedRoot(for folder: String, in assigned: [String: String]) -> String? {
        let target = normalized(folder)
        return assigned.keys.map(normalized)
            .filter { target == $0 || target.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            .max { $0.count < $1.count }
    }
}
