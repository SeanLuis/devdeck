import Foundation
import Testing
@testable import DevDeckCore

@Suite("Session library")
struct SessionLibraryTests {
    private func home() throws -> String {
        let home = NSTemporaryDirectory() + "devdeck-sessions-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/.claude/projects/-work-shop/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.codex/sessions/2026/11/02", withIntermediateDirectories: true)
        let claude = [
            #"{"type":"mode","mode":"default","sessionId":"abc"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignore</local-command-caveat>"},"cwd":"/work/shop","gitBranch":"main"}"#,
            #"{"parentUuid":"1","isSidechain":false,"type":"user","message":{"role":"user","content":"Fix the Checkout total\nwhen a coupon applies"},"cwd":"/work/shop","gitBranch":"main"}"#,
            #"{"type":"api-request-blob","hash":"h","message":{"role":"user","content":"Fix the Checkout total"}}"#,
            #"{"parentUuid":"2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"coupon maths"},{"type":"text","text":"The rounding in \"applyCoupon\" was wrong."},{"type":"tool_use","name":"Edit","input":{"file_path":"/work/shop/cart.ts"}}]},"cwd":"/work/shop","gitBranch":"fix/coupon"}"#,
            #"{"type":"ai-title","aiTitle":"Fix coupon rounding","sessionId":"abc"}"#,
        ]
        try (claude.joined(separator: "\n") + "\n").write(toFile: home + "/.claude/projects/-work-shop/abc.jsonl", atomically: true, encoding: .utf8)
        try #"{"type":"mode"}"#.write(toFile: home + "/.claude/projects/-work-shop/empty.jsonl", atomically: true, encoding: .utf8)
        try claude[2].write(toFile: home + "/.claude/projects/-work-shop/sub/agent.jsonl", atomically: true, encoding: .utf8)
        let codex = [
            #"{"timestamp":"2026-11-02T10:00:00Z","type":"session_meta","payload":{"id":"cx-1","cwd":"/work/api"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a health endpoint"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added GET /healthz."}]}}"#,
        ]
        try (codex.joined(separator: "\n") + "\n").write(toFile: home + "/.codex/sessions/2026/11/02/rollout-x.jsonl", atomically: true, encoding: .utf8)
        return home
    }

    @Test func listsSessionsWithTitleFolderAndBranch() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let all = SessionLibrary.list(home: home)
        #expect(all.count == 2)   // the bookkeeping file and the subagent are not sessions
        let claude = try #require(all.first { $0.agent == "Claude Code" })
        #expect(claude.title == "Fix coupon rounding")
        #expect(claude.project == "/work/shop")
        #expect(claude.sessionID == "abc")
        #expect(claude.resumeArguments == ["--resume", "abc"])
        let codex = try #require(all.first { $0.agent == "Codex" })
        #expect(codex.title == "Add a health endpoint")
        #expect(codex.project == "/work/api")
        #expect(codex.resumeArguments == ["resume", "cx-1"])
        // Unchanged files are taken from what was already known.
        var known = Dictionary(uniqueKeysWithValues: all.map { ($0.file, $0) })
        known[claude.file]?.title = "kept"
        #expect(SessionLibrary.list(home: home, known: known).first { $0.agent == "Claude Code" }?.title == "kept")
    }

    @Test func findsWhatWasSaidAndNothingElse() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let all = SessionLibrary.list(home: home)
        let claude = try #require(all.first { $0.agent == "Claude Code" })
        let asked = try #require(SessionLibrary.search("checkout TOTAL", in: claude))
        #expect(asked.fromUser)
        #expect(asked.count == 1)   // the copy kept for the API is not counted
        #expect(asked.snippet.contains("Checkout total when a coupon"))
        let answered = try #require(SessionLibrary.search("\"applycoupon\"", in: claude))
        #expect(!answered.fromUser)
        #expect(SessionLibrary.search("coupon maths", in: claude) == nil)   // thinking is not something that was said
        #expect(SessionLibrary.search("cart.ts", in: claude) == nil)
        #expect(SessionLibrary.search("x", in: claude) == nil)
        let codex = try #require(all.first { $0.agent == "Codex" })
        #expect(SessionLibrary.search("healthz", in: codex)?.fromUser == false)
        #expect(SessionLibrary.search("environment_context", in: codex) == nil)
    }

    @Test func findIgnoresAsciiCase() {
        let text = Array("say Hello, hELLo wörld".utf8)
        text.withUnsafeBytes { bytes in
            #expect(SessionLibrary.find(SessionLibrary.needle("HELLO"), in: bytes, from: 0) == 4)
            #expect(SessionLibrary.find(SessionLibrary.needle("hello"), in: bytes, from: 5) == 11)
            #expect(SessionLibrary.find(SessionLibrary.needle("wörld"), in: bytes, from: 0) == 17)
            #expect(SessionLibrary.find(SessionLibrary.needle("nope"), in: bytes, from: 0) == nil)
        }
    }

    @Test func resumeScriptQuotesTheFolder() {
        let entry = SessionEntry(agent: "Claude Code", file: "/x.jsonl", sessionID: "abc", project: "/work/it's here", title: "t", modified: Date(), sizeBytes: 1)
        let script = SessionLibrary.resumeScript(entry, binaryPath: "/usr/local/bin/claude")
        #expect(script.contains(#"cd '/work/it'\''s here' || exit 1"#))
        #expect(script.contains("exec '/usr/local/bin/claude' '--resume' 'abc'"))
    }
}

@Suite("Folder accounts")
struct FolderAccountTests {
    @Test func theClosestAssignedFolderWins() {
        let assigned = ["/work": "team", "/work/client/": "client", "/": "root"]
        #expect(FolderAccounts.account(for: "/work/client/app/src", in: assigned) == "client")
        #expect(FolderAccounts.account(for: "/work/clients", in: assigned) == "team")
        #expect(FolderAccounts.account(for: "/work", in: assigned) == "team")
        #expect(FolderAccounts.account(for: "/tmp/x", in: assigned) == "root")
        #expect(FolderAccounts.account(for: "/tmp/x", in: ["/work": "team"]) == nil)
        #expect(FolderAccounts.assignedRoot(for: "/work/client/app", in: assigned) == "/work/client")
    }
}

@Suite("Git work")
struct GitWorkTests {
    @Test func parsesWorktreesAndStatus() {
        let listed = """
        worktree /code/shop
        HEAD 1234567890abcdef
        branch refs/heads/main

        worktree /code/shop/.claude/worktrees/fix-coupon
        HEAD abcdef1234567890
        branch refs/heads/fix/coupon
        locked

        worktree /code/gone
        HEAD 0000000011111111
        detached
        prunable gitdir file points to non-existent location

        """
        let trees = GitWork.parseWorktrees(listed)
        #expect(trees.map(\.path) == ["/code/shop", "/code/shop/.claude/worktrees/fix-coupon", "/code/gone"])
        #expect(trees[0].isMain && trees[0].branch == "main" && trees[0].head == "12345678")
        #expect(trees[1].branch == "fix/coupon" && trees[1].locked && !trees[1].isMain)
        #expect(trees[2].branch == nil && trees[2].missing)
        let status = GitWork.parseStatus("## fix/coupon...origin/fix/coupon [ahead 2, behind 11]\n M cart.ts\n?? notes.md\n")
        #expect(status.changes == 2 && status.ahead == 2 && status.behind == 11)
        #expect(GitWork.parseStatus("## main\n").changes == 0)
    }

    @Test func aLeftoverWorktreeIsCleanOldAndUnattended() {
        let now = Date()
        var tree = GitWorktree(path: "/code/shop-wt")
        tree.lastCommit = now.addingTimeInterval(-30 * 86_400)
        #expect(tree.isLeftover(hasSession: false, now: now))
        #expect(!tree.isLeftover(hasSession: true, now: now))
        tree.changes = 1
        #expect(!tree.isLeftover(hasSession: false, now: now))
        tree.changes = 0
        tree.isMain = true
        #expect(!tree.isLeftover(hasSession: false, now: now))
        tree.isMain = false
        tree.lastCommit = now.addingTimeInterval(-86_400)
        #expect(!tree.isLeftover(hasSession: false, now: now))
        tree.missing = true
        #expect(tree.isLeftover(hasSession: false, now: now))
    }

    @Test func readsARealRepositoryAndRemovesAWorktree() async throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("devdeck-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repoPath = root + "/repo"
        let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com", "PATH": "/usr/bin:/bin", "HOME": root]
        func git(_ args: String...) async -> Bool { await Shell.run(GitWork.git, args, env: env, timeout: 30).ok }
        #expect(await git("init", "-q", "-b", "main", repoPath))
        try "one".write(toFile: repoPath + "/a.txt", atomically: true, encoding: .utf8)
        #expect(await git("-C", repoPath, "add", "."))
        #expect(await git("-C", repoPath, "commit", "-q", "-m", "first"))
        #expect(await git("-C", repoPath, "worktree", "add", "-q", "-b", "feature", root + "/wt"))
        try "new".write(toFile: root + "/wt/b.txt", atomically: true, encoding: .utf8)

        let repo = try #require(await GitWork.repo(containing: root + "/wt", env: env))
        #expect((repo.root as NSString).lastPathComponent == "repo")
        #expect(repo.worktrees.count == 2)
        let extra = try #require(repo.worktrees.first { !$0.isMain })
        #expect(extra.branch == "feature" && extra.changes == 1 && extra.lastCommit != nil && extra.sizeBytes != nil)
        #expect(GitWork.worktree(of: extra.path + "/src", in: [repo])?.branch == "feature")
        // Uncommitted work: git refuses, and so nothing is lost.
        #expect(!(await GitWork.remove(extra, from: repo, env: env)).ok)
        try FileManager.default.removeItem(atPath: root + "/wt/b.txt")
        #expect((await GitWork.remove(extra, from: repo, env: env)).ok)
        #expect(await GitWork.repo(containing: repoPath, env: env)?.worktrees.count == 1)
        #expect(await GitWork.repo(containing: root, env: env) == nil)
    }
}

@Suite("Daily digest")
struct DailyDigestTests {
    @Test func groupsTheDayByRepository() {
        var usage = AgentUsageReport()
        var spent = TokenCount()
        spent.input = 1_000_000; spent.output = 200_000; spent.messages = 4
        usage.buckets[UsageKey(agent: "Claude Code", day: "2026-11-14", model: "claude-sonnet-5-5", project: "/code/shop/.claude/worktrees/fix")] = spent
        usage.buckets[UsageKey(agent: "Codex", day: "2026-11-14", model: "unknown-model", project: "/code/api")] = spent
        usage.buckets[UsageKey(agent: "Claude Code", day: "2026-11-13", model: "claude-sonnet-5-5", project: "/code/shop")] = spent
        let noon = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        var moved = SessionEntry(agent: "Claude Code", file: "/a.jsonl", sessionID: "a", project: "/Users/me", title: "Fix coupon rounding", modified: noon, sizeBytes: 1)
        moved.workFolder = "/code/shop"
        let day = AgentUsageReport.dayString(noon)
        let digest = DailyDigests.build(day: day, usage: usage, prices: PriceTable(), sessions: [moved],
                                        commits: ["/code/shop": [DigestCommit(hash: "abc1234", subject: "Round totals")]], roots: ["/code/shop"])
        guard day == "2026-11-14" else { return }   // the fixture is written for this calendar day
        #expect(digest.projects.map(\.folder).sorted() == ["/code/api", "/code/shop"])
        let shop = digest.projects.first { $0.folder == "/code/shop" }
        #expect(shop?.tokens.billable == 1_200_000)   // the worktree's work counts with its repository; yesterday's does not
        #expect(shop?.sessions == ["Fix coupon rounding"])
        #expect(shop?.commits.count == 1)
        #expect(digest.commitCount == 1 && digest.sessionCount == 1)
        let text = DailyDigests.markdown(digest)
        #expect(text.contains("## shop"))
        #expect(text.contains("- `abc1234` Round totals"))
        #expect((DailyDigests.report(digest)["projects"] as? [[String: Any]])?.count == 2)
    }

    @Test func aChangeOnTwoBranchesIsOneCommit() {
        let parsed = DailyDigests.parseCommits("abc1234\tRound totals\ndef5678\tRound totals\n9990000\tAdd\ttabs in subject\n")
        #expect(parsed.map(\.hash) == ["abc1234", "9990000"])
        #expect(parsed.last?.subject == "Add\ttabs in subject")
    }
}

@Suite("Claude Code hooks")
struct ClaudeHooksTests {
    @Test func installsBesideOtherHooksAndRemovesOnlyItsOwn() throws {
        let home = NSTemporaryDirectory() + "devdeck-hooks-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let original = "{\n  \"model\": \"opus\",\n  \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"say done\"}]}]},\n  \"theme\":   \"dark\"\n}\n"
        try original.write(toFile: ClaudeHooks.settingsPath(home: home), atomically: true, encoding: .utf8)
        let command = ClaudeHooks.command(binary: "/Apps/Dev Deck.app/Contents/MacOS/DevDeck")
        try ClaudeHooks.apply(command: command, home: home)
        try ClaudeHooks.apply(command: command, home: home)   // twice: still one entry per event
        #expect(ClaudeHooks.installedCommand(home: home) == command)
        let text = try String(contentsOfFile: ClaudeHooks.settingsPath(home: home), encoding: .utf8)
        #expect(text.hasPrefix("{\n  \"model\": \"opus\",\n  \"hooks\": "))
        #expect(text.hasSuffix(",\n  \"theme\":   \"dark\"\n}\n"))   // the rest of the file is untouched
        let hooks = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2)
        #expect((hooks["Notification"] as? [[String: Any]])?.count == 1)
        #expect(try String(contentsOfFile: ClaudeHooks.settingsPath(home: home) + ".devdeck-backup", encoding: .utf8) == original)

        try ClaudeHooks.apply(command: nil, home: home)
        #expect(ClaudeHooks.installedCommand(home: home) == nil)
        let after = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: ClaudeHooks.settingsPath(home: home)))) as? [String: Any])?["hooks"] as? [String: Any])
        #expect(after.keys.sorted() == ["Stop"])
        #expect(((after["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "say done")
    }

    @Test func leavesABrokenSettingsFileAlone() throws {
        let home = NSTemporaryDirectory() + "devdeck-hooks-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try "{ not json".write(toFile: ClaudeHooks.settingsPath(home: home), atomically: true, encoding: .utf8)
        #expect(throws: ClaudeHooks.HookError.self) { try ClaudeHooks.apply(command: "x", home: home) }
        #expect(try String(contentsOfFile: ClaudeHooks.settingsPath(home: home), encoding: .utf8) == "{ not json")
        // No settings file at all: created with just the hooks.
        try FileManager.default.removeItem(atPath: ClaudeHooks.settingsPath(home: home))
        try ClaudeHooks.apply(command: nil, home: home)
        #expect(!FileManager.default.fileExists(atPath: ClaudeHooks.settingsPath(home: home)))
        try ClaudeHooks.apply(command: ClaudeHooks.command(binary: "/x"), home: home)
        #expect(ClaudeHooks.installedCommand(home: home) != nil)
    }

    @Test func recordsAndReadsEventsInOrder() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory() + "devdeck-events-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ask = #"{"hook_event_name":"Notification","session_id":"s1","cwd":"/code/shop","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}"#
        ClaudeHooks.record(Data(ask.utf8), directory: directory)
        ClaudeHooks.record(Data(#"{"hook_event_name":"PreToolUse","session_id":"s1"}"#.utf8), directory: directory)   // not one of ours
        ClaudeHooks.record(Data("garbage".utf8), directory: directory)
        var read = ClaudeHooks.read(directory: directory, from: 0)
        #expect(read.events.count == 1)
        #expect(read.events.first?.asksForInput == true)
        #expect(read.events.first?.cwd == "/code/shop")
        ClaudeHooks.record(Data(#"{"hook_event_name":"Stop","session_id":"s1","cwd":"/code/shop"}"#.utf8), directory: directory)
        read = ClaudeHooks.read(directory: directory, from: read.offset)
        #expect(read.events.map(\.event) == ["Stop"])
        #expect(read.events.first?.asksForInput == false)
        #expect(ClaudeHooks.read(directory: directory, from: read.offset).events.isEmpty)
        ClaudeHooks.trim(directory: directory, above: 10)
        #expect(ClaudeHooks.read(directory: directory, from: read.offset).offset == 0)
    }
}

@Suite("Agent requests")
struct AgentRequestTests {
    private func base() -> URL { URL(fileURLWithPath: NSTemporaryDirectory() + "devdeck-requests-" + UUID().uuidString) }

    @Test func nothingIsAskedWhenTheAppIsNotThere() async {
        let base = base()
        defer { try? FileManager.default.removeItem(at: base) }
        let answer = await AgentRequests.ask(AgentRequest(action: "free_port", port: 3000, reason: nil), base: base, patience: 1)
        #expect(answer["approved"] as? Bool == false)
        #expect((answer["detail"] as? String)?.contains("not open") == true)
        #expect(AgentRequests.pending(base: base).isEmpty)
        let bad = await AgentRequests.ask(AgentRequest(action: "rm_rf", port: 3000, reason: nil), base: base, patience: 1)
        #expect((bad["detail"] as? String)?.contains("Unknown") == true)
    }

    @Test func aRequestWaitsForThePersonAndCarriesTheAnswerBack() async {
        let base = base()
        defer { try? FileManager.default.removeItem(at: base) }
        AgentRequests.heartbeat(base: base)
        let request = AgentRequest(action: "free_port", port: 3000, reason: "next dev needs it")
        async let answer = AgentRequests.ask(request, base: base, patience: 5)
        var seen: [AgentRequest] = []
        for _ in 0..<40 where seen.isEmpty {
            try? await Task.sleep(nanoseconds: 50_000_000)
            seen = AgentRequests.pending(base: base)
        }
        #expect(seen.first?.port == 3000 && seen.first?.reason == "next dev needs it")
        AgentRequests.answer(AgentRequestResult(id: request.id, approved: true, done: true, detail: "Stopped."), base: base)
        let got = await answer
        #expect(got["approved"] as? Bool == true && got["done"] as? Bool == true && got["detail"] as? String == "Stopped.")
        #expect(AgentRequests.pending(base: base).isEmpty)
    }

    @Test func anUnansweredRequestChangesNothingAndExpires() async {
        let base = base()
        defer { try? FileManager.default.removeItem(at: base) }
        AgentRequests.heartbeat(base: base)
        let answer = await AgentRequests.ask(AgentRequest(action: "restart_server", port: 5173, reason: nil), base: base, patience: 0.5)
        #expect(answer["approved"] as? Bool == false)
        #expect(AgentRequests.pending(base: base).isEmpty)
        // One left behind by an agent that went away is dropped, not shown late.
        try? AgentRequests.submit(AgentRequest(action: "free_port", port: 1, reason: nil, at: Date().addingTimeInterval(-600)), base: base)
        #expect(AgentRequests.pending(base: base).isEmpty)
    }

    @Test func mcpPassesArgumentsAndRefusesWithoutThem() async {
        let base = base()
        defer { try? FileManager.default.removeItem(at: base) }
        let server = MCPServer.standard(version: "9", base: base)
        let list = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        let ask = tools.first { $0["name"] as? String == "request_free_port" }
        #expect((ask?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
        #expect(((ask?["inputSchema"] as? [String: Any])?["required"] as? [String]) == ["port"])
        #expect((tools.first { $0["name"] as? String == "listening_ports" }?["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        let without = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "request_free_port"]])
        #expect((without?["result"] as? [String: Any])?["isError"] as? Bool == true)
        let call = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "request_free_port", "arguments": ["port": 3000]]])
        let text = (((call?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("not open"))
    }
}

@Suite("Reset notices")
struct ResetNoticeTests {
    @Test func firesOnceWhenTheTimeComes() {
        let now = Date()
        let armed = ["a|5 h": now.timeIntervalSince1970 - 30, "b|7 días": now.timeIntervalSince1970 + 3600, "c|5 h": now.timeIntervalSince1970 - 2 * 86_400]
        let due = ResetNotices.due(armed, now: now)
        #expect(due.fired == ["a|5 h"])
        #expect(due.waiting.keys.sorted() == ["b|7 días"])   // the stale one is dropped without a word
    }

    @Test func armsItselfWhenTheAccountInUseRunsOut() {
        let now = Date()
        var account = AgentAccount(agent: "Claude Code", number: 1, email: "a@example.com", active: true)
        account.windows = [UsageWindow(name: "5 h", percent: 100, resetsAt: now.addingTimeInterval(1800)),
                           UsageWindow(name: "7 días", percent: 54, resetsAt: now.addingTimeInterval(86_400))]
        let armed = ResetNotices.autoArm(account, armed: [:], now: now)
        #expect(armed.keys.sorted() == [account.resetKey(account.windows[0])])
        // Already armed (or taken back and re-armed by hand): left as it is.
        #expect(ResetNotices.autoArm(account, armed: armed, now: now) == armed)
    }
}

@Suite("Project manifest")
struct ProjectManifestTests {
    private func root() throws -> String {
        let root = NSTemporaryDirectory() + "devdeck-manifest-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/apps/api", withIntermediateDirectories: true)
        return root
    }

    @Test func readsServicesAndDropsWhatCannotBeNamed() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(try ProjectManifest.load(root: root) == nil)
        let text = #"{"services":[{"name":"web","command":"pnpm dev","port":3000,"health":"/api/health"},{"name":"api","command":"PORT=4000 node server.js | tee log","dir":"apps/api","port":4000,"health":"http://localhost:4000/healthz"},{"name":"web","command":"dup"},{"name":"","command":"x"},{"name":"blank","command":"  "}],"compose":"infra/compose.yml"}"#
        try text.write(toFile: ProjectManifest.path(root: root), atomically: true, encoding: .utf8)
        let manifest = try #require(try ProjectManifest.load(root: root))
        #expect(manifest.services.map(\.name) == ["web", "api"])
        let web = manifest.recipe(for: manifest.services[0], root: root)
        #expect(web.argv == ["pnpm", "dev"] && web.cwd == root && web.ports == [3000] && web.env.isEmpty)
        let api = manifest.recipe(for: manifest.services[1], root: root)
        #expect(api.argv == ["/bin/zsh", "-l", "-c", "PORT=4000 node server.js | tee log"])   // a shell must read this one
        #expect(api.cwd == root + "/apps/api")
        #expect(manifest.healthURL(of: manifest.services[0])?.absoluteString == "http://127.0.0.1:3000/api/health")
        #expect(manifest.healthURL(of: manifest.services[1])?.absoluteString == "http://localhost:4000/healthz")
        #expect(manifest.composeFile(root: root) == nil)   // declared but not there
        try "{ nope".write(toFile: ProjectManifest.path(root: root), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try ProjectManifest.load(root: root) }
    }

    @Test func isWrittenFromRememberedCommandsWithoutTheirEnvironment() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let recipes = [
            LaunchRecipe(projectRoot: root, cwd: root, argv: ["pnpm", "dev", "--filter", "my app"], env: ["DATABASE_URL": "postgres://secret"], label: "Next.js", ports: [3000]),
            LaunchRecipe(projectRoot: root, cwd: root, argv: ["pnpm", "dev"], env: [:], label: "Next.js", ports: [3000]),   // older variant, same port
            LaunchRecipe(projectRoot: root, cwd: root + "/apps/api", argv: ["tsx", "watch", "src/server.ts"], env: ["TOKEN": "secret"], label: "tsx", ports: [4000]),
        ]
        let manifest = ProjectManifest.from(recipes: recipes, root: root, composeFile: root + "/compose.yaml")
        #expect(manifest.services.map(\.name) == ["Next.js", "tsx"])
        #expect(manifest.services[0].command == "pnpm dev --filter 'my app'")
        #expect(manifest.services[1].dir == "apps/api" && manifest.compose == "compose.yaml")
        try manifest.save(root: root)
        let written = try String(contentsOfFile: ProjectManifest.path(root: root), encoding: .utf8)
        #expect(!written.contains("secret"))
        #expect(try ProjectManifest.load(root: root) == manifest)
    }

    @Test func healthFollowsThePortAndTheAnswer() async {
        let manifest = ProjectManifest(services: [ManifestService(name: "web", command: "pnpm dev", port: 3999),
                                                  ManifestService(name: "dead", command: "node x.js", port: 1, health: "/healthz"),
                                                  ManifestService(name: "worker", command: "pnpm worker")])
        // Port 1 is "listened on" as far as the Mac's port list goes, but nothing answers there.
        let health = await ProjectHealth.check(manifest, root: "/p", services: [], boundPorts: [3999, 1])
        #expect(health["web"] == .running)
        #expect(health["worker"] == .down)
        if case .failing = health["dead"] {} else { Issue.record("a health address that does not answer must fail") }
        #expect(ServiceHealth.failing("x").isUp && !ServiceHealth.down.isUp)
    }
}

@Suite("Java build tools")
struct JavaLaunchTests {
    let wrapper = ["/Users/me/.sdkman/candidates/java/current/bin/java", "-Xmx64m", "-Xms64m", "-Xdock:name=Gradle", "-Dorg.gradle.appname=gradlew",
                   "-classpath", "/p/gradle/wrapper/gradle-wrapper.jar", "org.gradle.wrapper.GradleWrapperMain",
                   "-I", "/tmp/ai-run/fork-javac.gradle", "bootRun", "-PawsProfile=Sean", "--no-daemon"]

    @Test func aGradleWrapperLineBecomesWhatWasTyped() {
        let exists: (String) -> Bool = { $0 == "/p/gradlew" }
        #expect(JavaLaunch.kind(wrapper) == .gradleClient)
        // The agent's init script is gone: dropped, or the next run fails.
        #expect(JavaLaunch.userCommand(wrapper, cwd: "/p", fileExists: exists) == ["./gradlew", "bootRun", "-PawsProfile=Sean", "--no-daemon"])
        // Kept while it is there.
        #expect(JavaLaunch.userCommand(wrapper, cwd: "/p", fileExists: { _ in true })?.contains("-I") == true)
        #expect(JavaLaunch.userCommand(wrapper, cwd: "/elsewhere", fileExists: { _ in false })?.first == "gradle")
        let maven = ["/jdk/bin/java", "-classpath", "/m/boot/plexus-classworlds.jar", "-Dmaven.home=/m",
                     "org.codehaus.plexus.classworlds.launcher.Launcher", "spring-boot:run"]
        #expect(JavaLaunch.userCommand(maven, cwd: "/p", fileExists: { $0 == "/p/mvnw" }) == ["./mvnw", "spring-boot:run"])
        #expect(JavaLaunch.kind(["/jdk/bin/java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "9.2.1"]) == .gradleDaemon)
        #expect(JavaLaunch.kind(["/jdk/bin/java", "-cp", "app.jar", "com.acme.Application"]) == nil)
        #expect(JavaLaunch.userCommand(["node", "org.gradle.wrapper.GradleWrapperMain"], cwd: "/p") == nil)
    }

    @Test func rememberedCommandsAreCleaned() {
        func recipe(_ argv: [String], ports: [UInt16] = [], cwd: String = "/p") -> LaunchRecipe {
            LaunchRecipe(projectRoot: "/p", cwd: cwd, argv: argv, env: [:], label: argv.first ?? "", ports: ports)
        }
        let list = [
            recipe(["/usr/bin/git", "-C", "/p", "status"]),
            recipe(["gh", "pr", "view"]),
            recipe(["/jdk/bin/java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "9.2.1"], ports: [53840]),
            recipe(["pnpm", "dev"], ports: [3000]),
            recipe(["next", "dev"], ports: [3000]),          // older variant of the same server
            recipe(["pnpm", "worker"]),                        // no port, but a real command someone stopped
        ]
        let cleaned = LaunchRecipe.cleaned(list)
        #expect(cleaned.map(\.commandLine) == ["pnpm dev", "pnpm worker"])
    }

    @Test func theAppAGradleDaemonStartsBelongsToItsGradlew() {
        // The resolver only knows real folders in the home folder with a repository in them.
        let root = NSHomeDirectory() + "/DevDeckTest-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date()
        func proc(_ pid: Int32, _ ppid: Int32, _ args: [String], cwd: String?, start: TimeInterval) -> ProcessRecord {
            ProcessRecord(pid: pid, ppid: ppid, uid: getuid(), name: (args[0] as NSString).lastPathComponent, executablePath: args[0], args: args,
                          cwd: cwd, startTime: now.addingTimeInterval(start), memoryBytes: 100 << 20, cpuTimeNs: 0, cpuPercent: 1, isMine: true)
        }
        let client = proc(10, 1, wrapper.map { $0.replacingOccurrences(of: "/p/", with: root + "/") }, cwd: root, start: -60)
        let daemon = proc(20, 1, ["/jdk/bin/java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "9.2.1"],
                          cwd: "/Users/me/.gradle/daemon/9.2.1", start: -3600)
        let app = proc(30, 20, ["/jdk/bin/java", "-cp", "build/classes", "com.acme.Application"], cwd: root, start: -50)
        let worker = proc(40, 20, ["/jdk/bin/java", "worker.org.gradle.process.internal.worker.GradleWorkerMain", "Gradle Test Executor 1"], cwd: root, start: -40)
        let classifier = Classifier(resolver: ProjectResolver(), myUID: getuid(), selfPid: 999_999)
        let snapshot = classifier.build(processes: [client, daemon, app, worker], ports: [30: [RawListeningPort(port: 5500, address: "*")]],
                                        containers: [], now: now)
        let services = snapshot.groups.first { $0.projectRoot == root }?.services ?? []
        #expect(services.count == 1)
        let service = services.first
        #expect(service?.rootPid == 10)
        #expect(service?.ports == [5500])
        #expect(service?.pids.sorted() == [10, 30])   // the daemon and its test worker are not the project's service
        #expect(service?.userCommand?.hasSuffix("bootRun -PawsProfile=Sean --no-daemon") == true)
        #expect(snapshot.ports.first { $0.port == 5500 }?.serviceRootPid == 10)
    }
}

@Suite struct StatusLineRelayTests {
    func sandbox() throws -> (home: String, data: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-status-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        return (home, root.appendingPathComponent("data"))
    }

    @Test func readsTheLimitsClaudeCodeHandsItsStatusLine() throws {
        let input = Data(#"{"model":{"id":"x"},"rate_limits":{"five_hour":{"used_percentage":91.5,"resets_at":1795000000},"seven_day":{"used_percentage":40,"resets_at":"2026-11-20T10:00:00Z"}}}"#.utf8)
        let limits = try #require(ClaudeStatusLine.parse(input, email: "a@b.c"))
        #expect(limits.fiveHour?.percent == 91.5)
        #expect(limits.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_795_000_000))
        #expect(limits.sevenDay?.resetsAt != nil)
        #expect(limits.windows.map(\.name) == ["5 h", "7 días"])
        #expect(ClaudeStatusLine.parse(Data(#"{"rate_limits":null}"#.utf8), email: nil) == nil)
        #expect(ClaudeStatusLine.parse(Data(#"{"model":{}}"#.utf8), email: nil) == nil)
    }

    @Test func figuresGoToTheAccountWhoseWeekTheyAre() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let weekA = now.addingTimeInterval(3 * 86400), weekB = now.addingTimeInterval(5 * 86400)
        func reading(_ email: String, five: Double, week: Double, weekEnds: Date, ago: TimeInterval) -> ClaudeStatusLine.Limits {
            .init(email: email, fiveHour: .init(percent: five, resetsAt: now.addingTimeInterval(3600)),
                  sevenDay: .init(percent: week, resetsAt: weekEnds), at: now.addingTimeInterval(-ago))
        }
        // Switched from A to B: a session still open on A keeps drawing A's figures under B's email.
        let stale = reading("b@x.io", five: 90, week: 98, weekEnds: weekA, ago: 5)
        let fresh = reading("b@x.io", five: 10, week: 20, weekEnds: weekB, ago: 30)
        let b = ClaudeStatusLine.attribute([stale, fresh], email: "b@x.io", known: weekB, others: [weekA], now: now)
        #expect(b?.sevenDay?.percent == 20 && b?.fiveHour?.percent == 10)
        let a = ClaudeStatusLine.attribute([stale, fresh], email: "a@x.io", known: weekA, others: [weekB], now: now)
        #expect(a?.sevenDay?.percent == 98)
        // No week known yet: the email decides, unless the week is another account's.
        #expect(ClaudeStatusLine.attribute([stale, fresh], email: "b@x.io", known: nil, others: [weekA], now: now)?.sevenDay?.percent == 20)
        // Two sessions of the same account: the higher figure of the same window, not whichever drew last.
        let behind = reading("b@x.io", five: 4, week: 18, weekEnds: weekB, ago: 1)
        #expect(ClaudeStatusLine.attribute([fresh, behind], email: "b@x.io", known: weekB, others: [], now: now)?.fiveHour?.percent == 10)
        // Old readings stand for nothing.
        #expect(ClaudeStatusLine.attribute([reading("b@x.io", five: 1, week: 1, weekEnds: weekB, ago: 900)], email: "b@x.io", known: weekB, others: [], now: now) == nil)
        // The file keeps one reading per window pair, with the higher figure.
        let kept = ClaudeStatusLine.merged(ClaudeStatusLine.merged([fresh], adding: behind), adding: stale)
        #expect(kept.count == 2 && kept.first { ClaudeStatusLine.sameReset($0.sevenDay?.resetsAt, weekB) }?.sevenDay?.percent == 20)
    }

    @Test func tellsWhoseLoginATokenIs() {
        let identity = ClaudeOAuth.Identity(uuid: "u1", email: "a@x.io", organizationUuid: nil)
        #expect(AccountUsageService.judge(identity, uuid: "u1", email: "other@x.io") == .own)
        #expect(AccountUsageService.judge(identity, uuid: "u2", email: "a@x.io") == .foreign(identity))
        #expect(AccountUsageService.judge(identity, uuid: nil, email: "A@x.io") == .own)
        #expect(AccountUsageService.judge(identity, uuid: nil, email: "b@x.io") == .foreign(identity))
        #expect(ClaudeOAuth.parseProfile(Data(#"{"account":{"uuid":"u1","email":"a@x.io"},"organization":{"uuid":"o"}}"#.utf8)) == .init(uuid: "u1", email: "a@x.io", organizationUuid: "o"))
        #expect(ClaudeOAuth.parseProfile(Data(#"{"account":{}}"#.utf8)) == nil)
        // The login's own lapse, not the access token's.
        let credential = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1795000000000,"refreshTokenExpiresAt":1797490025978}}"#
        #expect(ClaudeCredential.loginExpiresAt(credential) == Date(timeIntervalSince1970: 1_797_490_025.978))
        #expect(!ClaudeCredential.isLoginExpired(credential, now: Date(timeIntervalSince1970: 1_796_000_000)))
        #expect(ClaudeCredential.isLoginExpired(credential, now: Date(timeIntervalSince1970: 1_798_000_000)))
    }

    @Test func putsTheRelayInFrontAndGivesTheOriginalBack() throws {
        let box = try sandbox()
        let settings = box.home + "/.claude/settings.json"
        let original = #"{"theme": "dark", "statusLine": {"type": "command", "command": "printf hola", "padding": 1}}"#
        try original.write(toFile: settings, atomically: true, encoding: .utf8)
        let command = ClaudeStatusLine.command(binary: "/Apps/DevDeck")
        try ClaudeStatusLine.apply(command: command, directory: box.data, home: box.home)
        #expect(ClaudeStatusLine.installedCommand(home: box.home) == command)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as? [String: Any])
        #expect((root["statusLine"] as? [String: Any])?["padding"] as? Int == 1)
        #expect(root["theme"] as? String == "dark")
        // Applied twice (the app moved): the original is still the person's, not the relay.
        try ClaudeStatusLine.apply(command: ClaudeStatusLine.command(binary: "/Other/DevDeck"), directory: box.data, home: box.home)
        #expect(ClaudeStatusLine.originalCommand(directory: box.data) == "printf hola")

        // The relay keeps the limits and prints what the original printed.
        try #"{"oauthAccount": {"emailAddress": "me@x.io"}, "big": [1, 2, 3]}"#.write(toFile: box.home + "/.claude.json", atomically: true, encoding: .utf8)
        let output = ClaudeStatusLine.relay(input: Data(#"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1795000000}}}"#.utf8),
                                            directory: box.data, home: box.home)
        #expect(String(decoding: output, as: UTF8.self) == "hola")
        let kept = try #require(ClaudeStatusLine.read(directory: box.data))
        #expect(kept.email == "me@x.io" && kept.fiveHour?.percent == 12)

        try ClaudeStatusLine.apply(command: nil, directory: box.data, home: box.home)
        let back = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as? [String: Any])
        #expect((back["statusLine"] as? [String: Any])?["command"] as? String == "printf hola")
    }

    @Test func withoutAStatusLineBeforeTurningItOffLeavesNone() throws {
        let box = try sandbox()
        let settings = box.home + "/.claude/settings.json"
        try #"{"theme": "dark"}"#.write(toFile: settings, atomically: true, encoding: .utf8)
        try ClaudeStatusLine.apply(command: ClaudeStatusLine.command(binary: "/Apps/DevDeck"), directory: box.data, home: box.home)
        #expect(ClaudeStatusLine.relay(input: Data("{}".utf8), directory: box.data, home: box.home).isEmpty)
        try ClaudeStatusLine.apply(command: nil, directory: box.data, home: box.home)
        let back = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: settings))) as? [String: Any])
        #expect(back["statusLine"] == nil && back["theme"] as? String == "dark")
    }
}
