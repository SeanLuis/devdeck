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
        // A busy machine can take a while to answer `ps`: wait for the state instead of trusting one look.
        func settles(_ stopped: Bool) -> Bool {
            for _ in 0..<50 {
                let now = state()
                if !now.isEmpty, now.hasPrefix("T") == stopped { return true }
                usleep(100_000)
            }
            return false
        }
        #expect(settles(true))
        // A pid that now belongs to a different process (other start time) is left alone.
        #expect(ProcessPauser.resume(paused, liveStarts: [pid: Date().addingTimeInterval(-500)]) == 0)
        #expect(ProcessPauser.resume(paused, liveStarts: [pid: record.startTime]) == 1)
        #expect(settles(false))
    }
}

@Suite("Process roles")
struct ProcessRoleTests {
    private func role(_ name: String, _ args: [String], path: String = "/Applications/Google Chrome.app/Contents/Frameworks/X/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper") -> String? {
        ProcessRole.of(name: name, executablePath: path, args: args)?.key
    }

    @Test func namesBrowserHelpers() {
        #expect(role("Google Chrome Helper (Renderer)", ["helper", "--type=renderer", "--seatbelt-client=138"]) == "renderer")
        #expect(role("Google Chrome Helper (Renderer)", ["helper", "--type=renderer", "--extension-process"]) == "extension")
        #expect(role("Google Chrome Helper (GPU)", ["helper", "--type=gpu-process"]) == "gpu")
        #expect(role("Google Chrome Helper", ["helper", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == "network")
        #expect(role("Google Chrome Helper", ["helper", "--type=utility", "--utility-sub-type=audio.mojom.AudioService"]) == "audio")
        #expect(role("chrome_crashpad_handler", ["x"]) == "crash")
    }

    @Test func leavesOrdinaryProcessesAlone() {
        #expect(ProcessRole.of(name: "Google Chrome", executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", args: ["Google Chrome"]) == nil)
        #expect(ProcessRole.of(name: "node", executablePath: "/usr/local/bin/node", args: ["node", "server.js"]) == nil)
        #expect(ProcessRole.of(name: "node", executablePath: "/usr/local/bin/node", args: ["node", "/x/typescript/lib/tsserver.js"])?.key == "tsserver")
    }
}

@Suite("Own usage")
struct OwnUsageTests {
    @Test func readsUsageFromEachProvider() {
        let claude = OwnUsage.tokens(fromUsage: ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20])
        #expect(claude.input == 10 && claude.cacheRead == 100 && claude.cacheWrite == 20 && claude.output == 5)
        let codex = OwnUsage.tokens(fromUsage: ["input_tokens": 120, "cached_input_tokens": 100, "output_tokens": 7])
        #expect(codex.input == 20 && codex.cacheRead == 100 && codex.output == 7)
        #expect(OwnUsage.tokens(fromUsage: nil).total == 0)
    }

    @Test func keepsALedgerPerDayAndPurpose() {
        let ledger = OwnUsage()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-own-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        ledger.use(directory: dir)
        var tokens = TokenCount(); tokens.input = 100; tokens.messages = 1
        let now = Date()
        ledger.record(purpose: "copilot", model: "m", tokens: tokens, date: now)
        ledger.record(purpose: "automatic", model: "m", tokens: tokens, date: now.addingTimeInterval(-3 * 86_400))
        #expect(ledger.summary(lastDays: 1, now: now).total.input == 100)
        #expect(ledger.summary(lastDays: 7, now: now).total.input == 200)
        #expect(ledger.summary(lastDays: 7, now: now).purposes["automatic"]?.messages == 1)
        // A fresh instance reads what was written.
        let again = OwnUsage()
        again.use(directory: dir)
        #expect(again.summary(lastDays: 7, now: now).total.input == 200)
    }
}

@Suite("Timeline")
struct TimelineTests {
    private func point(_ minute: Int, mem: Double = 60, swap: Int = 1000, pressure: Int = 1, sources: [(String, Int)]) -> TimelinePoint {
        TimelinePoint(minute: minute, memPercent: mem, memUsedMB: 20_000, swapMB: swap, cpu: 10, pressure: pressure,
                      sources: sources.map { TimelinePoint.Source(id: $0.0, name: $0.0, kind: "project", memMB: $0.1, cpu: 1) })
    }

    @Test func storesAndLoadsARange() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-timeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineStore(directory: dir)
        let base = Int(Date().timeIntervalSince1970 / 60) - 100
        for offset in 0..<100 { store.append(point(base + offset, sources: [("a", offset)])) }
        let all = store.load(from: Date().addingTimeInterval(-3 * 3600))
        #expect(all.count == 100)
        #expect(all.first?.minute == base && all.last?.sources.first?.memMB == 99)
        let recent = TimelineStore(directory: dir).load(from: Date(timeIntervalSince1970: Double(base + 90) * 60))
        #expect(recent.count == 10)
    }

    @Test func findsWhatOnlyGrows() {
        var points: [TimelinePoint] = []
        for minute in 0..<180 {
            points.append(point(minute, sources: [("leaky", 800 + minute * 8), ("busy", 900 + (minute % 20) * 60), ("flat", 1500)]))
        }
        let leaks = TimelineAnalysis.leaks(points)
        #expect(leaks.map(\.id) == ["leaky"])
        #expect((leaks.first?.growthMB ?? 0) > 800)
        #expect(TimelineAnalysis.leaks(Array(points.prefix(20))).isEmpty)
    }

    @Test func marksMomentsAndNamesTheCulprit() {
        var points: [TimelinePoint] = []
        for minute in 0..<120 {
            let spike = minute >= 60 && minute < 66
            points.append(point(minute, mem: spike ? 94 : 60, sources: [("builder", spike ? 6000 : 900), ("other", 1000)]))
        }
        let moments = TimelineAnalysis.moments(points)
        #expect(moments.count == 1)
        #expect(moments.first?.minute == 60 && moments.first?.culprit == "builder")
        #expect(TimelineAnalysis.thin(points, to: 30).count == 30)
    }
}

@Suite("Budgets")
struct BudgetTests {
    static func usage(now: Date) -> AgentUsageReport {
        var report = AgentUsageReport()
        func tokens(_ n: UInt64) -> TokenCount { var t = TokenCount(); t.output = n; t.cacheRead = n * 9; t.messages = 1; return t }
        let today = AgentUsageReport.dayString(now)
        let before = AgentUsageReport.dayString(now.addingTimeInterval(-3 * 86_400))
        report.buckets[UsageKey(agent: "Claude Code", day: today, model: "m", project: "/code/shop")] = tokens(4_000_000)
        report.buckets[UsageKey(agent: "Claude Code", day: before, model: "m", project: "/code/shop/packages/ui")] = tokens(5_000_000)
        report.buckets[UsageKey(agent: "Codex", day: today, model: "g", project: "/code/shopping")] = tokens(1_000_000)
        return report
    }

    @Test func countsByScopeAndPeriod() {
        let now = Date()
        let usage = Self.usage(now: now)
        func used(_ kind: Budget.Kind, _ target: String, _ period: Budget.Period) -> Double {
            Budgets.status(Budget(kind: kind, target: target, period: period, limit: 1), usage: usage, accounts: .empty, now: now).used
        }
        // Cache reads are not counted; a subfolder belongs to its project, a sibling with the same prefix does not.
        #expect(used(.project, "/code/shop", .week) == 9_000_000)
        #expect(used(.project, "/code/shop", .day) == 4_000_000)
        #expect(used(.agent, "Codex", .week) == 1_000_000)
        #expect(used(.all, "", .week) == 10_000_000)
        #expect(used(.all, "", .day) == 5_000_000)
    }

    @Test func announcesEachLevelOncePerPeriod() {
        let now = Date()
        let usage = Self.usage(now: now)
        let budget = Budget(kind: .all, period: .week, limit: 12_000_000)
        var fired: [String: String] = [:]
        let first = Budgets.evaluate([budget], usage: usage, accounts: .empty, fired: &fired, now: now)
        #expect(first.map(\.level) == [80])
        #expect(Budgets.evaluate([budget], usage: usage, accounts: .empty, fired: &fired, now: now).isEmpty)
        var over = budget
        over.limit = 9_000_000
        #expect(Budgets.evaluate([over], usage: usage, accounts: .empty, fired: &fired, now: now).map(\.level) == [100])
        // The next day it may be announced again; a removed budget leaves no state behind.
        #expect(Budgets.evaluate([over], usage: usage, accounts: .empty, fired: &fired, now: now.addingTimeInterval(86_400)).count == 1)
        _ = Budgets.evaluate([], usage: usage, accounts: .empty, fired: &fired, now: now)
        #expect(fired.isEmpty)
    }

    @Test func accountBudgetReadsTheWindow() {
        var accounts = AccountsReport()
        var account = AgentAccount(agent: "Claude Code", email: "a@example.com", active: true)
        account.windows = [UsageWindow(name: "7 días", percent: 82, resetsAt: Date().addingTimeInterval(3600))]
        accounts.accounts = [account]
        let week = Budgets.status(Budget(kind: .account, target: "a@example.com", period: .week, limit: 75), usage: .empty, accounts: accounts)
        #expect(week.measurable && week.fraction > 1)
        let fiveHours = Budgets.status(Budget(kind: .account, target: "a@example.com", period: .day, limit: 75), usage: .empty, accounts: accounts)
        #expect(!fiveHours.measurable)
        var fired: [String: String] = [:]
        #expect(Budgets.evaluate([fiveHours.budget], usage: .empty, accounts: accounts, fired: &fired).isEmpty)
    }
}

@Suite("Agent waiting")
struct AgentWaitTests {
    static func session(_ status: String, entry: String = "cli") -> LiveAgentSession {
        LiveAgentSession(pid: 10, sessionID: "s1", cwd: "/code/shop", status: status, name: nil, entrypoint: entry, startedAt: nil, updatedAt: nil)
    }

    @Test func announcesTheEndOfALongTurnOnce() {
        var tracker = AgentWaitTracker(minimumWork: 45)
        let start = Date()
        #expect(tracker.update([Self.session("idle")], now: start).isEmpty)
        #expect(tracker.update([Self.session("busy")], now: start.addingTimeInterval(10)).isEmpty)
        #expect(tracker.update([Self.session("busy")], now: start.addingTimeInterval(60)).isEmpty)
        let events = tracker.update([Self.session("idle")], now: start.addingTimeInterval(100))
        #expect(events.map(\.reason) == [.finished])
        #expect(events.first.map { Int($0.worked) } == 90)
        #expect(tracker.update([Self.session("idle")], now: start.addingTimeInterval(110)).isEmpty)
    }

    @Test func ignoresShortTurnsUnattendedSessionsAndFirstSight() {
        var tracker = AgentWaitTracker(minimumWork: 45)
        let start = Date()
        // Already idle when first seen after being busy elsewhere: nothing to say.
        #expect(tracker.update([Self.session("busy")], now: start).isEmpty)
        #expect(tracker.update([Self.session("idle")], now: start.addingTimeInterval(5)).isEmpty)
        #expect(tracker.update([Self.session("busy", entry: "sdk-ts")], now: start.addingTimeInterval(10)).isEmpty)
        #expect(tracker.update([Self.session("idle", entry: "sdk-ts")], now: start.addingTimeInterval(500)).isEmpty)
    }

    @Test func aQuestionIsAnnouncedEvenAfterAShortTurn() {
        var tracker = AgentWaitTracker(minimumWork: 45)
        let start = Date()
        _ = tracker.update([Self.session("idle")], now: start)
        _ = tracker.update([Self.session("busy")], now: start.addingTimeInterval(1))
        #expect(tracker.update([Self.session("waiting_for_permission")], now: start.addingTimeInterval(4)).map(\.reason) == [.needsInput])
    }
}

@Suite("Agent activity")
struct AgentActivityTests {
    @Test func readsTheLastStepFromTheTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            #"{"type":"assistant","timestamp":"2026-11-13T10:00:00.000Z","message":{"content":[{"type":"text","text":"Voy a mirar.\nSegunda línea"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-11-13T10:00:05.000Z","message":{"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Edit","input":{"file_path":"/code/shop/src/cart.ts"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"done"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let activity = try #require(AgentActivityReader.claude(transcript: url.path))
        #expect(activity.tool == "Edit")
        #expect(activity.summary == "Edit · cart.ts")
        #expect(activity.at != nil)
        let text = try #require(AgentActivityReader.parseClaude(line: Data(lines[0].utf8)))
        #expect(text.tool == nil && text.detail == "Voy a mirar.")
    }

    @Test func describesToolsByTheirMostTellingArgument() {
        #expect(AgentActivityReader.toolDetail(name: "Bash", input: ["command": "swift test\n--filter X", "description": "Run tests"]) == "Run tests")
        #expect(AgentActivityReader.toolDetail(name: "Bash", input: ["command": "swift test\n--filter X"]) == "swift test")
        #expect(AgentActivityReader.toolDetail(name: "Grep", input: ["pattern": "TODO"]) == "TODO")
        #expect(AgentActivityReader.clip(String(repeating: "a", count: 300)).count == 110)
    }
}

@Suite("Pricing")
struct PricingTests {
    @Test func pricesByLongestPrefixAndLeavesUnknownModelsOut() {
        let table = PriceTable()
        var tokens = TokenCount()
        tokens.input = 1_000_000; tokens.output = 1_000_000; tokens.cacheRead = 10_000_000; tokens.cacheWrite = 1_000_000
        // Opus 5.5: 4 + 20 + 10 × 0.20 + 1.25 × 4
        #expect(abs((table.cost(tokens, model: "claude-opus-5-5[1m]") ?? 0) - 31) < 0.0001)
        #expect(table.price(for: "claude-opus-5-20260101")?.input == 5)
        #expect(table.cost(tokens, model: "gpt-6-astra") == nil)

        var report = AgentUsageReport()
        report.buckets[UsageKey(agent: "Claude Code", day: "2026-11-13", model: "claude-opus-5-5", project: "/a")] = tokens
        report.buckets[UsageKey(agent: "Codex", day: "2026-11-13", model: "gpt-6-astra", project: "/a")] = tokens
        let all = report.cost(table)
        #expect(all.partial && all.text == "≥ $31.00")
        #expect(report.cost(table) { $0.agent == "Codex" }.text == "—")
    }

    @Test func userPricesOverrideAndExtend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"[{"match":"gpt-6","input":1,"output":8},{"match":"claude-opus-5-5","input":40,"output":200,"cacheRead":2,"cacheWrite":50}]"#
            .write(to: dir.appendingPathComponent("prices.json"), atomically: true, encoding: .utf8)
        let table = PriceTable.load(directory: dir)
        #expect(table.price(for: "gpt-6-astra")?.cacheWrite == 1.25)
        #expect(table.price(for: "claude-opus-5-5")?.input == 40)
        #expect(table.price(for: "claude-sonnet-5-5")?.output == 10)
    }
}

@Suite("Agent leftovers")
struct AgentLeftoverTests {
    static func process(_ pid: Int32, parent: Int32, _ args: [String], exe: String = "/usr/local/bin/node", minutes: Double = 60, mb: UInt64 = 100) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: parent, uid: 501, name: (exe as NSString).lastPathComponent, executablePath: exe, args: args, cwd: "/code/shop",
                      startTime: Date().addingTimeInterval(-minutes * 60), memoryBytes: mb << 20, cpuTimeNs: 0, cpuPercent: 1, isMine: true)
    }

    @Test func findsOnlyOrphansThatAnAgentLeft() {
        let list = [
            Self.process(10, parent: 1, ["node", "/x/node_modules/@modelcontextprotocol/server-github/dist/index.js"]),
            Self.process(11, parent: 10, ["node", "worker.js"], mb: 50),
            Self.process(20, parent: 1, ["/bin/zsh", "-c", "source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && pnpm dev"], exe: "/bin/zsh", mb: 4),
            Self.process(21, parent: 20, ["node", "/code/shop/node_modules/.bin/next", "dev"], mb: 900),
            // Still has its agent, too young, or simply an ordinary app: not leftovers.
            Self.process(30, parent: 99, ["node", "mcp-server-foo"]),
            Self.process(31, parent: 1, ["node", "mcp-server-bar"], minutes: 2),
            Self.process(32, parent: 1, ["/Applications/Safari.app/Contents/MacOS/Safari"], exe: "/Applications/Safari.app/Contents/MacOS/Safari"),
        ]
        let found = AgentLeftovers.find(processes: Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0) }), listening: [21: [3000]], ownPid: 1234)
        #expect(found.map(\.rootPid) == [20, 10])
        #expect(found[0].kind == .command && found[0].pids.sorted() == [20, 21] && found[0].ports == [3000])
        #expect(found[0].command.contains("next"))
        #expect(found[1].kind == .toolServer && found[1].memoryBytes == 150 << 20)
    }
}

@Suite("Project start")
struct ProjectStartTests {
    @Test func plansOnlyWhatIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "services: {}".write(toFile: root + "/compose.yaml", atomically: true, encoding: .utf8)
        let web = LaunchRecipe(projectRoot: root, cwd: root + "/web", argv: ["pnpm", "dev"], env: [:], label: "web", ports: [3000])
        let webOld = LaunchRecipe(projectRoot: root, cwd: root + "/web", argv: ["pnpm", "dev", "--turbo"], env: [:], label: "web turbo", ports: [3000])
        let api = LaunchRecipe(projectRoot: root, cwd: root + "/api", argv: ["pnpm", "start"], env: [:], label: "api", ports: [4000])
        let worker = LaunchRecipe(projectRoot: root, cwd: root + "/worker", argv: ["node", "worker.js"], env: [:], label: "worker")
        let live = ServiceInfo(rootPid: 7, label: "worker", command: "node worker.js", cwd: root + "/worker", appDir: nil, dirs: [root + "/worker"],
                               framework: nil, ports: [], memoryBytes: 0, cpuPercent: 0, pids: [7], startTime: Date())
        let plan = ProjectStart.plan(root: root, recipes: [web, webOld, api, worker], services: [live], boundPorts: [4000], containers: [], dockerAvailable: true)
        #expect(plan.recipes.map(\.label) == ["web"])
        #expect(plan.alreadyRunning == 2)
        #expect(plan.composeFile?.hasSuffix("compose.yaml") == true)
        #expect(ProjectStart.plan(root: root, recipes: [], services: [], boundPorts: [], containers: [], dockerAvailable: false).isEmpty)
    }
}

@Suite("Work profiles")
struct WorkProfileTests {
    @Test func plansWhatToStartAndClose() {
        var profile = WorkProfile(name: "Tienda", projects: ["/code/shop", "/code/api"], closeOtherProjects: true, closeHeadless: true)
        let plan = WorkProfiles.plan(profile, running: ["/code/api", "/code/docs"], headlessRunning: false)
        #expect(plan.start == ["/code/shop"] && plan.close == ["/code/docs"] && !plan.closeHeadless)
        profile.closeOtherProjects = false
        #expect(WorkProfiles.plan(profile, running: ["/code/api", "/code/shop", "/code/docs"], headlessRunning: false).isEmpty)
        #expect(WorkProfiles.plan(profile, running: ["/code/api", "/code/shop"], headlessRunning: true).closeHeadless)
    }
}

@Suite("Power")
struct PowerTests {
    @Test func batteryRuleOnlyFiresUnplugged() {
        let rule = Rule(name: "Batería baja", metric: .batteryPercent, threshold: 20, sustainSeconds: 0, cooldownSeconds: 0)
        var power = PowerStatus()
        power.batteryPercent = 12
        power.onAC = true
        #expect(RuleEngine().evaluate(rules: [rule], snapshot: .empty, system: .empty, power: power).isEmpty)
        power.onAC = false
        #expect(RuleEngine().evaluate(rules: [rule], snapshot: .empty, system: .empty, power: power).count == 1)
        #expect(RuleEngine().evaluate(rules: [rule], snapshot: .empty, system: .empty, power: .unknown).isEmpty)
        let heat = Rule(name: "Calor", metric: .thermalLevel, threshold: 1, sustainSeconds: 0, cooldownSeconds: 0)
        power.thermalLevel = 3
        #expect(RuleEngine().evaluate(rules: [heat], snapshot: .empty, system: .empty, power: power).first?.severity == .critical)
    }

    @Test func readingThePowerSourcesDoesNotCrash() {
        let status = PowerStatus.read()
        #expect((0...3).contains(status.thermalLevel))
        if let percent = status.batteryPercent { #expect((0...100).contains(percent)) }
    }
}

@Suite("Reports and MCP")
struct ReportsTests {
    @Test func tablesAlignAndJSONIsStable() {
        let rows: [[String: Any]] = [["name": "shop", "memory_gb": 2.5, "ports": [3000, 4000]], ["name": "a-long-name", "memory_gb": 1.0]]
        #expect(Reports.table(rows, columns: ["name", "memory_gb", "ports"]) == "name         memory_gb  ports\nshop         2.5        3000,4000\na-long-name  1")
        #expect(Reports.json(["b": 1, "a": "/x/y"]).contains("\"a\" : \"/x/y\""))
    }

    @Test func mcpAnswersTheHandshakeAndRunsTools() async throws {
        let server = MCPServer(version: "9", tools: [.init(name: "echo", description: "d") { ["ok": true] }])
        let hello = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        let info = (hello?["result"] as? [String: Any])
        #expect(info?["protocolVersion"] as? String == "2025-03-26" && (info?["serverInfo"] as? [String: Any])?["name"] as? String == "devdeck")
        #expect(await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect(((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.first?["name"] as? String == "echo")
        let call = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "echo"]])
        let text = (((call?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("\"ok\" : true"))
        let missing = await server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]])
        #expect((missing?["result"] as? [String: Any])?["isError"] as? Bool == true)
        let unknown = await server.handle(["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
        #expect(unknown?["error"] != nil)
    }
}

@Suite("Custom recipes")
struct CustomRecipeTests {
    @Test func readsRecipesFromData() {
        let json = #"[{"tool":"docker","group":"Docker","title":"Reiniciar proxy","command":["docker","restart","proxy"],"destructive":false},{"title":"Limpiar","command":["rm -rf ~/x"],"shell":true},{"title":"sin comando"}]"#
        let recipes = Toolkit.parseCustom(Data(json.utf8))
        #expect(recipes.count == 2)
        #expect(recipes[0].id == "custom-0" && recipes[0].tool == "docker" && !recipes[0].destructive)
        #expect(recipes[1].shell && recipes[1].destructive && recipes[1].tool == "sh" && recipes[1].group == "Propias")
        #expect(Toolkit.parseCustom(Data("{}".utf8)).isEmpty)
    }
}

@Suite struct MenuBarAccountTests {
    @Test func titleShowsBothWindowsAndWarns() {
        let now = Date()
        let later = now.addingTimeInterval(3600)
        let calm = [UsageWindow(name: "5 h", percent: 2.4, resetsAt: later), UsageWindow(name: "7 días", percent: 54, resetsAt: later)]
        #expect(AgentAccount.menuBarTitle(windows: calm, warnAt: 90, now: now) == "✦ 2% · 54%")
        let hot = [UsageWindow(name: "5 h", percent: 93, resetsAt: later), UsageWindow(name: "7 días", percent: 54, resetsAt: later)]
        #expect(AgentAccount.menuBarTitle(windows: hot, warnAt: 90, now: now) == "! 93% · 54%")
        let reset = [UsageWindow(name: "5 h", percent: 80, resetsAt: now.addingTimeInterval(-60)), UsageWindow(name: "7 días", percent: 54, resetsAt: later)]
        #expect(AgentAccount.menuBarTitle(windows: reset, warnAt: 90, now: now) == "✦ — · 54%")
        #expect(AgentAccount.menuBarTitle(windows: [], warnAt: 90, now: now) == nil)
    }

    @Test func activeAccountIsReadSoonerWhileTheAgentWorks() {
        let now = Date()
        func due(_ ago: TimeInterval, active: Bool, busy: Bool, backoff: TimeInterval? = nil, entry: AccountUsage? = nil) -> Bool {
            AccountUsageService.isDue(last: now.addingTimeInterval(-ago), entry: entry, active: active, busy: busy, backoff: backoff,
                                      interval: 300, activeInterval: 90, now: now)
        }
        #expect(due(100, active: true, busy: true))
        #expect(!due(100, active: true, busy: false))
        #expect(!due(100, active: false, busy: true))
        #expect(due(301, active: false, busy: false))
        #expect(!due(400, active: true, busy: true, backoff: 600))
        var old = AccountUsage()
        old.windows = [.init(name: "5 h", percent: 80, resetsAt: now.addingTimeInterval(-10))]
        #expect(due(61, active: false, busy: false, entry: old))
        #expect(AccountUsageService.isDue(last: nil, entry: nil, active: false, busy: false, backoff: nil, interval: 300, activeInterval: 90, now: now))
    }

    @Test func unsavedLoginKeepsItsOwnReading() async throws {
        let home = NSTemporaryDirectory() + "devdeck-live-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try #"{"oauthAccount":{"emailAddress":"Solo@Example.com"}}"#.write(toFile: home + "/.claude.json", atomically: true, encoding: .utf8)
        var reading = AccountUsage()
        reading.windows = [.init(name: "5 h", percent: 12, resetsAt: Date().addingTimeInterval(3600))]
        reading.fetchedAt = Date()
        let report = await AgentAccounts.load(env: [:], codexPlan: nil, home: home, usage: [AccountUsageService.liveKey("solo@example.com"): reading])
        let account = try #require(report.accounts(of: "Claude Code").first)
        #expect(account.active)
        #expect(account.windows.first?.percent == 12)
    }
}
