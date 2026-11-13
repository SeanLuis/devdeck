import Foundation
import Testing
@testable import DevDeckCore

/// End-to-end: a real server is discovered by its port, its launch context captured,
/// killed, and relaunched from the recipe with the same env.
@Suite("Restart integration", .serialized)
struct RestartIntegrationTests {
    func freePort() -> UInt16 {
        var port: UInt16 = 0
        repeat { port = UInt16.random(in: 41_000...48_000) } while ProcessControl.isListening(port: port)
        return port
    }

    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    @Test func captureKillAndRelaunch() async throws {
        let port = freePort()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-it-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        server.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["DEVDECK_MARKER"] = "kept-\(port)"
        server.environment = env
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        #expect(await waitFor(10) { ProcessControl.isListening(port: port) })

        // 1. Discover the port owner and capture its launch context.
        let sampler = Sampler()
        _ = await sampler.sample()
        let (snapshot, _) = await sampler.sample()
        let binding = try #require(snapshot.ports.first { $0.port == port })
        #expect(binding.pid == server.processIdentifier)
        let context = try #require(await sampler.launchContext(of: binding.pid))
        #expect(context.args.contains("http.server"))
        #expect(context.env["DEVDECK_MARKER"] == "kept-\(port)")

        // 2. Kill it and wait for the port to be released.
        let result = await ProcessControl.terminate([binding.pid], grace: 3)
        #expect(result.graceful + result.forced == 1)
        await ProcessControl.waitUntilFree(ports: [port], timeout: 5)
        #expect(!ProcessControl.isListening(port: port))

        // 3. Relaunch from the recipe: same argv, cwd and env.
        let recipe = LaunchRecipe(projectRoot: dir.path, cwd: dir.path, argv: context.args, env: context.env, label: "test", ports: [port])
        let (relaunched, log) = try ProcessControl.launch(recipe, logDirectory: dir.appendingPathComponent("logs"), fallbackEnv: env)
        defer { relaunched.terminate() }
        #expect(await waitFor(10) { ProcessControl.isListening(port: port) })
        #expect(FileManager.default.fileExists(atPath: log.path))

        let again = try #require(await sampler.launchContext(of: relaunched.processIdentifier))
        #expect(again.env["DEVDECK_MARKER"] == "kept-\(port)")
        #expect(again.env["DEVDECK_MANAGED"] == "1")
    }
}
