import Foundation

/// Java build tools run as JVMs whose command line is not what the person typed: `./gradlew bootRun` shows up as
/// `java -Xmx64m … org.gradle.wrapper.GradleWrapperMain bootRun`, and the app itself is a separate JVM started by
/// a Gradle daemon. This tells them apart and gives back the command worth remembering.
public enum JavaLaunch {
    public enum Kind: Equatable, Sendable {
        /// `./gradlew …` or `gradle …`: what the person ran.
        case gradleClient
        /// `./mvnw …` or `mvn …`.
        case mavenClient
        /// The long-lived Gradle process that runs builds for every project; never a project's own service.
        case gradleDaemon
        /// A helper JVM a build starts (tests, compilation).
        case gradleWorker
    }

    private static let mains: [(String, Kind)] = [
        ("org.gradle.wrapper.GradleWrapperMain", .gradleClient),
        ("org.gradle.launcher.GradleMain", .gradleClient),
        ("org.gradle.launcher.daemon.bootstrap.GradleDaemon", .gradleDaemon),
        ("worker.org.gradle.process.internal.worker.GradleWorkerMain", .gradleWorker),
        ("org.gradle.process.internal.worker.GradleWorkerMain", .gradleWorker),
        ("org.apache.maven.wrapper.MavenWrapperMain", .mavenClient),
        ("org.codehaus.plexus.classworlds.launcher.Launcher", .mavenClient),
    ]

    static func isJava(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        return (first as NSString).lastPathComponent == "java"
    }

    /// Where the launcher's main class sits in the command, and which launcher it is.
    static func main(_ args: [String]) -> (index: Int, kind: Kind, name: String)? {
        guard isJava(args) else { return nil }
        for (index, arg) in args.enumerated() where !arg.hasPrefix("-") {
            if let hit = mains.first(where: { $0.0 == arg }) { return (index, hit.1, hit.0) }
        }
        return nil
    }

    public static func kind(_ args: [String]) -> Kind? { main(args)?.kind }

    /// The command as the person would type it in `cwd`, or nil when it is not a build tool's launcher.
    /// Init scripts that no longer exist (agents leave them in temporary folders) are dropped, or the next run fails.
    public static func userCommand(_ args: [String], cwd: String?, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String]? {
        guard let found = main(args), found.kind == .gradleClient || found.kind == .mavenClient else { return nil }
        func resolve(_ path: String) -> String { path.hasPrefix("/") || cwd == nil ? path : cwd! + "/" + path }
        var rest: [String] = []
        var index = found.index + 1
        while index < args.count {
            let arg = args[index]
            if arg == "-I" || arg == "--init-script", index + 1 < args.count {
                if fileExists(resolve(args[index + 1])) { rest += [arg, args[index + 1]] }
                index += 2
                continue
            }
            if arg.hasPrefix("--init-script=") {
                if fileExists(resolve(String(arg.dropFirst("--init-script=".count)))) { rest.append(arg) }
                index += 1
                continue
            }
            rest.append(arg)
            index += 1
        }
        let tool: String
        switch found.name {
        case "org.gradle.wrapper.GradleWrapperMain": tool = cwd.map { fileExists($0 + "/gradlew") } == true ? "./gradlew" : "gradle"
        case "org.gradle.launcher.GradleMain": tool = "gradle"
        default: tool = cwd.map { fileExists($0 + "/mvnw") } == true ? "./mvnw" : "mvn"
        }
        return [tool] + rest
    }
}
