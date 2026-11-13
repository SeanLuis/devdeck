import Foundation

/// A named way of working: the projects that should be up, and what gets out of the way.
public struct WorkProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Project folders this profile needs running.
    public var projects: [String]
    /// Close the projects that are running and are not part of the profile.
    public var closeOtherProjects: Bool
    /// Close the windowless browsers agents leave behind.
    public var closeHeadless: Bool

    public init(id: UUID = UUID(), name: String, projects: [String], closeOtherProjects: Bool = true, closeHeadless: Bool = false) {
        self.id = id; self.name = name; self.projects = projects
        self.closeOtherProjects = closeOtherProjects; self.closeHeadless = closeHeadless
    }
}

/// What switching to a profile would do. Always shown to the user before anything happens.
public struct WorkProfilePlan: Hashable, Sendable {
    public var start: [String] = []
    public var close: [String] = []
    public var closeHeadless = false

    public var isEmpty: Bool { start.isEmpty && close.isEmpty && !closeHeadless }
}

public enum WorkProfiles {
    public static func plan(_ profile: WorkProfile, running: Set<String>, headlessRunning: Bool) -> WorkProfilePlan {
        var plan = WorkProfilePlan()
        plan.start = profile.projects.filter { !running.contains($0) }
        if profile.closeOtherProjects { plan.close = running.subtracting(profile.projects).sorted() }
        plan.closeHeadless = profile.closeHeadless && headlessRunning
        return plan
    }
}
