import Foundation

/// What "start the whole project" would do: the remembered commands that are not running yet, and its containers.
public struct ProjectStartPlan: Hashable, Sendable {
    public var recipes: [LaunchRecipe] = []
    /// Compose file to bring up, when the project has one and its containers are not all running.
    public var composeFile: String?
    /// Remembered commands left out because they already run.
    public var alreadyRunning = 0

    public var isEmpty: Bool { recipes.isEmpty && composeFile == nil }
    public var steps: Int { recipes.count + (composeFile == nil ? 0 : 1) }
}

public enum ProjectStart {
    static let composeNames = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]

    public static func composeFile(in root: String) -> String? {
        composeNames.map { root + "/" + $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// A remembered command counts as running when one of its ports is taken or a live service runs the same thing in the same folder.
    public static func isRunning(_ recipe: LaunchRecipe, services: [ServiceInfo], boundPorts: Set<UInt16>) -> Bool {
        if recipe.ports.contains(where: boundPorts.contains) { return true }
        let wanted = ProcessControl.normalizedArgv(recipe.argv).joined(separator: " ")
        return services.contains { service in
            (service.cwd == recipe.cwd || service.dirs.contains(recipe.cwd)) && (service.command == wanted || service.command == recipe.commandLine)
        }
    }

    public static func plan(root: String, recipes: [LaunchRecipe], services: [ServiceInfo], boundPorts: Set<UInt16>,
                            containers: [ContainerInfo], dockerAvailable: Bool) -> ProjectStartPlan {
        var plan = ProjectStartPlan()
        var claimed = Set<UInt16>()
        for recipe in recipes {
            if isRunning(recipe, services: services, boundPorts: boundPorts) { plan.alreadyRunning += 1; continue }
            // Two remembered variants of the same server (same port) must not fight: keep the most recent.
            if recipe.ports.contains(where: claimed.contains) { continue }
            claimed.formUnion(recipe.ports)
            plan.recipes.append(recipe)
        }
        if dockerAvailable, let file = composeFile(in: root) {
            let mine = containers.filter { $0.workingDir == root }
            if mine.isEmpty || mine.contains(where: { !$0.isRunning }) { plan.composeFile = file }
        }
        return plan
    }
}
