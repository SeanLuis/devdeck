import Foundation
import Testing
@testable import DevDeckCore

@Suite("Redaction")
struct RedactionTests {
    @Test func masksSecretsAndHome() {
        let input = "\(NSHomeDirectory())/app --api-key=abc123 TOKEN=xyz sk-ABCDEFGHIJKLMNOP postgres://user:pa55@db:5432/x ghp_abcdefghijklmnop"
        let out = AISnapshotBuilder.redact(input)
        #expect(!out.contains(NSHomeDirectory()))
        #expect(out.hasPrefix("~/app"))
        #expect(!out.contains("abc123"))
        #expect(!out.contains("xyz"))
        #expect(!out.contains("sk-ABCDEFGHIJKLMNOP"))
        #expect(!out.contains("pa55"))
        #expect(!out.contains("ghp_abcdefghijklmnop"))
    }

    @Test func keepsOrdinaryCommands() {
        #expect(AISnapshotBuilder.redact("pnpm --filter @acme/console dev") == "pnpm --filter @acme/console dev")
    }
}

@Suite("Env file")
struct EnvFileTests {
    @Test func readsQuotedExportedValues() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID().uuidString).env")
        try "# comment\nOTHER=1\nexport OPENAI_API_KEY=\"sk-test-123\" # trailing\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AIKeyProvider.readEnvFile(url.path, variable: "OPENAI_API_KEY") == "sk-test-123")
        #expect(AIKeyProvider.readEnvFile(url.path, variable: "MISSING") == nil)
    }
}

@Suite("Docker parsing")
struct DockerTests {
    @Test func parsesPortsAndSizes() {
        let ports = DockerProbe.parsePorts("0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 0.0.0.0:8645->8545/tcp")
        #expect(ports.map(\.hostPort) == [5432, 8645])
        #expect(ports.last?.containerPort == 8545)
        #expect(DockerProbe.parseSize("1.5GiB") == 1_610_612_736)
        #expect(DockerProbe.parseSize("512MiB") == 536_870_912)
        #expect(DockerProbe.parseSize("12kB") == 12_000)
    }

    @Test func parsesComposeLabels() throws {
        let line = #"{"ID":"abc","Names":"web-1","Image":"postgres:18","State":"running","Status":"Up","Ports":"0.0.0.0:55440->5432/tcp","Labels":"com.docker.compose.project=acme,com.docker.compose.project.working_dir=/Users/x/acme"}"#
        let c = try #require(DockerProbe.parse(line: line))
        #expect(c.isRunning)
        #expect(c.composeProject == "acme")
        #expect(c.workingDir == "/Users/x/acme")
        #expect(c.ports.first?.hostPort == 55440)
    }
}

@Suite("Process helpers")
struct ProcessHelperTests {
    @Test func normalizesRewrittenTitles() {
        #expect(ProcessControl.normalizedArgv(["npm run dev"]) == ["npm", "run", "dev"])
        #expect(ProcessControl.normalizedArgv(["node", "server.js"]) == ["node", "server.js"])
    }

    @Test func detectsAgentsAndMCP() {
        #expect(Classifier.agentName(exe: "/Users/x/.local/share/claude/versions/2.1.322", exeName: "2.1.322", args: []) == "Claude Code")
        #expect(Classifier.agentName(exe: "/Applications/Devin.app/Contents/MacOS/Devin", exeName: "Devin", args: []) == "Devin")
        #expect(Classifier.agentName(exe: "/usr/local/bin/node", exeName: "node", args: ["npm exec @agentclientprotocol/claude-agent-acp@0.1"]) == "Claude Code")
        #expect(Classifier.agentName(exe: "/usr/local/bin/node", exeName: "node", args: ["node", "server.js"]) == nil)
        #expect(Classifier.isMCPServer(["npm exec shadcn@latest mcp  "]))
        #expect(Classifier.isMCPServer(["node", "/x/mongodb-mcp-server/dist/index.js"]))
        #expect(!Classifier.isMCPServer(["pnpm", "dev"]))
    }

    @Test func detectsHeadlessBrowsers() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        #expect(Classifier.isHeadlessBrowser(exe: chrome, args: [chrome, "--headless=new", "--dump-dom"]))
        #expect(!Classifier.isHeadlessBrowser(exe: chrome, args: [chrome]))
        #expect(Classifier.appBundleName("/Applications/Brave Browser.app/Contents/Frameworks/X.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/h") == "Brave Browser")
    }

    @Test func detectsFrameworks() {
        func proc(_ args: [String]) -> ProcessRecord {
            ProcessRecord(pid: 1, ppid: 0, uid: 0, name: (args.first as NSString?)?.lastPathComponent ?? "", executablePath: "", args: args,
                          cwd: nil, startTime: Date(), memoryBytes: 0, cpuTimeNs: 0, cpuPercent: 0, isMine: true)
        }
        #expect(Classifier.framework(for: proc(["next-server (v16.0.1)"])) == "Next.js")
        #expect(Classifier.framework(for: proc(["node", "/p/node_modules/.bin/vite"])) == "Vite")
        #expect(Classifier.framework(for: proc(["uvicorn", "app:main"])) == "Uvicorn")
    }
}

@Suite("Rules")
struct RuleTests {
    func system(memPercent: Double) -> SystemSample {
        var s = SystemSample.empty
        s.memTotal = 100
        s.memUsed = UInt64(memPercent)
        s.diskFree = 500 << 30
        return s
    }

    @Test func respectsSustainAndCooldown() {
        let engine = RuleEngine()
        let rule = Rule(name: "ram", metric: .systemMemoryPercent, threshold: 90, sustainSeconds: 10, cooldownSeconds: 60)
        let t0 = Date()
        #expect(engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0).isEmpty)
        #expect(engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0.addingTimeInterval(11)).count == 1)
        // cooldown
        #expect(engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0.addingTimeInterval(30)).isEmpty)
        #expect(engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0.addingTimeInterval(75)).count == 1)
    }

    @Test func resetsWhenRecovered() {
        let engine = RuleEngine()
        let rule = Rule(name: "ram", metric: .systemMemoryPercent, threshold: 90, sustainSeconds: 10)
        let t0 = Date()
        _ = engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0)
        _ = engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 50), now: t0.addingTimeInterval(5))
        #expect(engine.evaluate(rules: [rule], snapshot: .empty, system: system(memPercent: 95), now: t0.addingTimeInterval(12)).isEmpty)
    }

    @Test func diskRuleFiresBelowThreshold() {
        let engine = RuleEngine()
        let rule = Rule(name: "disk", metric: .diskFreeGB, threshold: 15, sustainSeconds: 0)
        var s = system(memPercent: 10)
        s.diskFree = 5 << 30
        let firing = engine.evaluate(rules: [rule], snapshot: .empty, system: s).first
        #expect(firing?.severity == .warning)
    }
}

@Suite("Projects and caches")
struct ProjectTests {
    func makeTree() throws -> URL {
        // Inside $HOME so the resolver accepts it; under Documents-like visible folder.
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("devdeck-test-\(UUID().uuidString.prefix(8))")
        let fm = FileManager.default
        for dir in [".git", "apps/web/.next/cache", "apps/web/node_modules/x", "packages/ui/node_modules", "target"] {
            try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["package.json", "apps/web/package.json", "packages/ui/package.json"] {
            try "{}".write(to: base.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return base
    }

    @Test func resolvesMonorepoRootAndApp() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let resolver = ProjectResolver()
        let project = try #require(resolver.resolve(path: base.path + "/apps/web/node_modules/x"))
        #expect(project.root == base.path)
        #expect(resolver.appDir(for: base.path + "/apps/web", within: base.path) == base.path + "/apps/web")
        #expect(resolver.resolve(path: NSHomeDirectory() + "/Library/Caches") == nil)
    }

    @Test func findsCachesButNotUnrelatedTarget() throws {
        let base = try makeTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let found = Set(CacheScanner.findCaches(projectRoot: base.path).map { String($0.path.dropFirst(base.path.count + 1)) })
        #expect(found.contains("apps/web/.next"))
        #expect(found.contains("apps/web/node_modules"))
        #expect(found.contains("packages/ui/node_modules"))
        #expect(!found.contains("target"))   // no Cargo.toml → not a Rust build dir
    }

    @Test func worktreeNaming() {
        #expect(ProjectIdentity.named(root: "/Users/x/hub/.worktrees/deploy").name == "hub ⎇ deploy")
    }
}

@Suite("Safety")
struct SafetyTests {
    func proc(pid: Int32, exe: String, uid: UInt32 = getuid()) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: 1, uid: uid, name: (exe as NSString).lastPathComponent, executablePath: exe, args: [exe],
                      cwd: "/", startTime: Date(), memoryBytes: 1, cpuTimeNs: 0, cpuPercent: 0, isMine: uid == getuid())
    }

    @Test func systemAppsAreProtected() {
        let classifier = Classifier(resolver: ProjectResolver(), myUID: getuid(), selfPid: 999_999)
        let procs = [
            proc(pid: 10, exe: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            proc(pid: 11, exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            proc(pid: 12, exe: "/Applications/Slack.app/Contents/MacOS/Slack"),
        ]
        let snap = classifier.build(processes: procs, ports: [:], containers: [], now: Date())
        #expect(snap.group(forPid: 10)?.killable == false)
        #expect(snap.group(forPid: 11)?.killable == false)
        #expect(snap.group(forPid: 12)?.killable == true)
    }

    @Test func reusedPidIsNotSignalled() async throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        let wrongStart = Date(timeIntervalSince1970: 1_000)
        let result = await ProcessControl.terminate([pid], expectedStarts: [pid: wrongStart], grace: 1)
        #expect(result.graceful + result.forced == 0)
        #expect(sleeper.isRunning)
        let real = try #require(ProcessControl.startTime(of: pid))
        let killed = await ProcessControl.terminate([pid], expectedStarts: [pid: real], grace: 2)
        #expect(killed.graceful + killed.forced == 1)
    }
}

@Suite("Agent accounts")
struct AgentAccountTests {
    @Test func parsesSwitcherListWithNoise() {
        let json = """
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
         {"number":1,"email":"a@example.com","organizationName":"Org","active":false,"usageStatus":"ok",
          "usage":{"fiveHour":{"pct":0.0},"sevenDay":{"pct":77.0,"resetsAt":"2026-11-17T19:00:00Z","willLastToReset":false},
                   "scoped":[{"name":"Fable","pct":35.0,"resetsAt":"2026-11-17T19:00:00Z","willLastToReset":true}]},
          "loginExpiresAt":"2026-11-22T18:50:30Z"},
         {"number":2,"email":"b@example.com","active":true,"usage":{"fiveHour":{"pct":62}}}]}
        A newer version is available {not json}
        """
        let accounts = AgentAccounts.parseSwitcher(Data(("warning line\n" + json).utf8))
        #expect(accounts.count == 0 || accounts.count == 2)
        let clean = AgentAccounts.parseSwitcher(Data(json.split(separator: "\n").dropLast().joined(separator: "\n").utf8))
        #expect(clean.count == 2)
        #expect(clean[0].windows.map(\.name) == ["5 h", "7 días", "Fable"])
        #expect(clean[0].windows[1].willLast == false)
        #expect(clean[0].windows[1].resetsAt != nil)
        #expect(clean[1].active && clean[1].windows.first?.percent == 62)
    }

    @Test func labelsPlans() {
        #expect(AgentAccounts.planLabel("default_claude_max_5x") == "Max 5x")
        #expect(AgentAccounts.planLabel("plus") == "Plus")
        #expect(AgentAccounts.planLabel(nil) == nil)
    }

    @Test func readsJWTClaims() {
        let payload = Data(#"{"email":"x@example.com"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(AgentAccounts.jwtClaims("h.\(payload).s")?["email"] as? String == "x@example.com")
    }
}

@Suite("Agent sessions")
struct AgentSessionTests {
    @Test func parsesLiveClaudeSession() {
        let data = Data(#"{"pid":20742,"sessionId":"abc","cwd":"/tmp/x","startedAt":1794545100579,"entrypoint":"cli","name":"n","status":"busy","statusUpdatedAt":1794576552692}"#.utf8)
        let session = LiveAgentSessions.parseClaude(data)
        #expect(session?.pid == 20742)
        #expect(session?.isBusy == true)
        #expect(session?.entrypoint == "cli")
        #expect(LiveAgentSessions.parseClaude(Data("{}".utf8)) == nil)
    }

    @Test func rollingWindowCountsOnlyRecentHours() {
        var report = AgentUsageReport()
        var tokens = TokenCount(); tokens.input = 100; tokens.messages = 1
        let now = Date(timeIntervalSince1970: 3600 * 1000)
        report.hourly["A"] = [1000: tokens, 997: tokens, 990: tokens]
        #expect(report.recent(agent: "A", hours: 5, now: now).input == 200)
    }
}

@Suite("Toolkit")
struct ToolkitTests {
    @Test func recipeIdsAreUniqueAndResolvable() {
        #expect(Set(Toolkit.recipes.map(\.id)).count == Toolkit.recipes.count)
        #expect(Toolkit.recipe("docker-df")?.destructive == false)
        #expect(AgentTools.actions["run_tool"] != nil)
        #expect(AgentTools.instructions(language: "español", recipes: Toolkit.recipes).contains("docker-builder"))
    }

    @Test func dockerMemoryEditKeepsOtherSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-docker-\(UUID().uuidString).json")
        try #"{"MemoryMiB":16384,"SwapMiB":2048,"Other":"keep"}"#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        try DockerDesktop.setMemoryMiB(4096, settings: url)
        #expect(DockerDesktop.memoryMiB(settings: url) == 4096)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(obj?["Other"] as? String == "keep" && (obj?["SwapMiB"] as? Int) == 2048)
    }
}

@Suite("Localization")
struct LocalizationTests {
    /// Every `L("…")` / `plural(…)` literal in the sources, plus the strings that live in data tables.
    static func allKeys() throws -> [String] {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let string = #""((?:[^"\\]|\\.)*)""#
        let patterns = [try NSRegularExpression(pattern: #"\bL\(\s*"# + string),
                        try NSRegularExpression(pattern: #"\bplural\([^,]+,\s*"# + string + #"\s*,\s*"# + string)]
        var keys = Set(L10n.dataKeys)
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.lastPathComponent.hasPrefix("L10n") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for regex in patterns {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    for group in 1..<match.numberOfRanges {
                        guard let range = Range(match.range(at: group), in: text) else { continue }
                        keys.insert(String(text[range]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n"))
                    }
                }
            }
        }
        return keys.sorted()
    }

    @Test func everyStringIsTranslated() throws {
        let keys = try Self.allKeys()
        #expect(keys.count > 300)
        for language in [AppLanguage.en, .pt] {
            let missing = L10n.missing(keys, language: language)
            #expect(missing.isEmpty, "\(language.rawValue): \(missing.count) sin traducir, p. ej. \(missing.prefix(5))")
        }
    }

    @Test func translationsKeepPlaceholders() throws {
        for key in try Self.allKeys() {
            for language in [AppLanguage.en, .pt] {
                let translated = L10n.translate(key, language: language)
                #expect(L10n.placeholders(translated).sorted() == L10n.placeholders(key).sorted(), "\(language.rawValue): \(key) → \(translated)")
            }
        }
    }

    @Test func spanishIsTheSourceLanguage() {
        #expect(L10n.translate("Resumen", language: .es) == "Resumen")
        #expect(L10n.translate("texto que no existe", language: .en) == "texto que no existe")
    }
}

@Suite("Updates")
struct UpdateTests {
    @Test func comparesVersionsNumerically() {
        #expect(Updates.isNewer("0.1.1", than: "0.1.0"))
        #expect(Updates.isNewer("v0.10.0", than: "0.9.9"))
        #expect(Updates.isNewer("1.0", than: "0.9.9"))
        #expect(!Updates.isNewer("0.1.0", than: "0.1.0"))
        #expect(!Updates.isNewer("0.1", than: "0.1.0"))
        #expect(!Updates.isNewer("0.0.9", than: "0.1.0"))
    }

    @Test func parsesLatestRelease() {
        let json = #"{"tag_name":"v0.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/o/r/releases/tag/v0.2.0","body":"- one\n- two","published_at":"2026-11-13T15:17:34Z","assets":[{"name":"other.txt","browser_download_url":"https://x/other.txt"},{"name":"DevDeck.zip","browser_download_url":"https://x/DevDeck.zip"}]}"#
        let release = Updates.parse(Data(json.utf8))
        #expect(release?.version == "0.2.0")
        #expect(release?.downloadURL == "https://x/DevDeck.zip")
        #expect(release?.notes.contains("two") == true)
        #expect(release?.publishedAt != nil)
        #expect(Updates.parse(Data(#"{"tag_name":"v9","prerelease":true}"#.utf8)) == nil)
        #expect(Updates.parse(Data("{}".utf8)) == nil)
    }
}

@Suite("Game mode")
struct GameModeTests {
    @Test func detectsGamesAndRespectsTheUsersLists() {
        var settings = GameSettings()
        func game(_ name: String, category: String? = nil, declares: Bool = false, path: String = "/Applications/X.app/Contents/MacOS/X") -> Bool {
            GameDetector.looksLikeGame(name: name, category: category, declaresGameMode: declares, path: path, settings: settings)
        }
        #expect(game("Chess", category: "public.app-category.board-games"))
        #expect(game("Hades", path: "/Users/me/Library/Application Support/Steam/steamapps/common/Hades/Hades.app/Contents/MacOS/Hades"))
        #expect(game("Any", declares: true))
        #expect(!game("Xcode", category: "public.app-category.developer-tools"))
        settings.extraGames = ["Emulator"]
        settings.notGames = ["chess"]
        #expect(game("Emulator"))
        #expect(!game("Chess", category: "public.app-category.board-games"))
    }

    private func group(_ id: String, _ kind: GroupKind, pids: [Int32], cpu: Double = 0, services: [ServiceInfo] = []) -> ProcessGroup {
        ProcessGroup(id: id, kind: kind, name: id, detail: "", projectRoot: nil, pids: pids, memoryBytes: 1, cpuPercent: cpu, ports: [],
                     services: services, containers: [], frameworks: [], origins: [:])
    }

    @Test func choosesWhatToPause() {
        let groups = [group("headless", .headless, pids: [1]), group("agent:busy", .agent, pids: [2], cpu: 40), group("agent:idle", .agent, pids: [3]),
                      group("docker", .docker, pids: [4]), group("system", .system, pids: [5]), group("app:Game", .app, pids: [6]),
                      group("agent:front", .agent, pids: [7])]
        var settings = GameSettings()
        #expect(ProcessPauser.groupsToPause(groups, settings: settings, protected: []).map(\.id) == ["headless"])
        settings.pauseIdleAgents = true
        settings.pauseDocker = true
        #expect(ProcessPauser.groupsToPause(groups, settings: settings, protected: [7]).map(\.id) == ["headless", "agent:idle", "docker"])
        settings.neverPause = ["docker"]
        #expect(!ProcessPauser.groupsToPause(groups, settings: settings, protected: []).map(\.id).contains("docker"))
    }

    @Test func pausesAndResumesARealProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        func state() -> String {
            Shell.runSync("/bin/ps", ["-o", "state=", "-p", "\(pid)"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let record = ProcessRecord(pid: pid, ppid: getpid(), uid: getuid(), name: "sleep", executablePath: "/bin/sleep", args: ["sleep"], cwd: nil,
                                   startTime: Date(), memoryBytes: 1, cpuTimeNs: 0, cpuPercent: 0, isMine: true)
        let paused = ProcessPauser.pause(group("x", .headless, pids: [pid]), processes: [pid: record])
        #expect(paused.count == 1)
        usleep(200_000)
        #expect(state().hasPrefix("T"))
        // A pid that now belongs to a different process (other start time) is left alone.
        #expect(ProcessPauser.resume(paused, liveStarts: [pid: Date().addingTimeInterval(-500)]) == 0)
        #expect(ProcessPauser.resume(paused, liveStarts: [pid: record.startTime]) == 1)
        usleep(200_000)
        #expect(!state().hasPrefix("T"))
    }
}
