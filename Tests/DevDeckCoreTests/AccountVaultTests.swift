import Foundation
import Testing
@testable import DevDeckCore

/// A fake home folder and a throwaway keychain file: no test here reads or writes a real login.
final class VaultSandbox {
    let root: URL
    let home: String
    let keychain: Keychain
    let vault: AccountVault

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-vault-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let path = root.appendingPathComponent("test.keychain-db").path
        #expect(Keychain.run(["create-keychain", "-p", "", path]).status == 0)
        _ = Keychain.run(["set-keychain-settings", path])
        _ = Keychain.run(["unlock-keychain", "-p", "", path])
        keychain = Keychain(path: path)
        vault = AccountVault(home: home, directory: root.appendingPathComponent("data"), keychain: keychain, user: "tester")
    }

    deinit {
        if let path = keychain.path { _ = Keychain.run(["delete-keychain", path]) }
        try? FileManager.default.removeItem(at: root)
    }

    static func login(_ name: String, expiresIn: TimeInterval = 3600, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["claudeAiOauth": ["accessToken": "access-\(name)", "refreshToken": "refresh-\(name)",
                                                      "expiresAt": Int((Date().timeIntervalSince1970 + expiresIn) * 1000), "scopes": ["user:inference"]]]
        for (key, value) in extra { object[key] = value }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func profile(_ email: String, org: String) -> [String: Any] {
        ["emailAddress": email, "organizationUuid": org, "organizationName": "Org \(org)", "accountUuid": "acc-\(email)"]
    }

    /// Logs the fake Claude Code in: its keychain item and its config file.
    func logIn(_ email: String, org: String, credentials: String) throws {
        try keychain.set(service: AccountVault.claudeService, account: "tester", secret: credentials)
        let config: [String: Any] = ["numStartups": 42, "theme": "dark", "ratio": 0.1, "oauthAccount": Self.profile(email, org: org),
                                     "projects": ["/code/a": ["allowedTools": ["Bash(ls:*)"]]]]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: home + "/.claude.json"))
    }

    func config() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/.claude.json"))) as? [String: Any]
        return try #require(object)
    }

    /// Lays out what claude-swap keeps: its registry, a config snapshot per account and a keychain copy of each login.
    func installClaudeSwap(_ accounts: [(number: Int, email: String, org: String, credentials: String?)], active: Int) throws {
        let base = home + "/.claude-swap-backup"
        try FileManager.default.createDirectory(atPath: base + "/configs", withIntermediateDirectories: true)
        var registry: [String: Any] = [:]
        for account in accounts {
            registry[String(account.number)] = ["email": account.email, "uuid": "acc-\(account.email)", "organizationUuid": account.org,
                                                "organizationName": "Org \(account.org)", "added": "2026-11-01T00:00:00Z"]
            let snapshot: [String: Any] = ["numStartups": 1, "oauthAccount": Self.profile(account.email, org: account.org)]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: URL(fileURLWithPath: base + "/configs/.claude-config-\(account.number)-\(account.email).json"))
            if let credentials = account.credentials {
                try keychain.set(service: "claude-swap", account: "account-\(account.number)-\(account.email)", secret: credentials)
            }
        }
        let sequence: [String: Any] = ["activeAccountNumber": active, "lastUpdated": "x", "sequence": accounts.map(\.number), "accounts": registry]
        try JSONSerialization.data(withJSONObject: sequence, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: base + "/sequence.json"))
    }
}

@Suite("Keychain", .serialized)
struct KeychainTests {
    @Test func storesReadsAndDeletesSecrets() throws {
        let box = try VaultSandbox()
        #expect(try box.keychain.get(service: "svc", account: "a") == nil)
        let secret = #"{"k":"with \"quotes\" and \\ slashes","n":1}"#
        try box.keychain.set(service: "svc with space", account: "user@example.com", secret: secret)
        #expect(try box.keychain.get(service: "svc with space", account: "user@example.com") == secret)
        // Longer than the tool's line buffer: must still arrive whole.
        let long = String(repeating: "abcdefghij", count: 900)
        try box.keychain.set(service: "svc with space", account: "user@example.com", secret: long)
        #expect(try box.keychain.get(service: "svc with space", account: "user@example.com") == long)
        try box.keychain.delete(service: "svc with space", account: "user@example.com")
        #expect(!box.keychain.exists(service: "svc with space", account: "user@example.com"))
        try box.keychain.delete(service: "svc with space", account: "user@example.com")
    }
}

@Suite("JSON splice")
struct JSONSpliceTests {
    @Test func replacesOneValueAndLeavesTheRestByteForByte() throws {
        let text = "{\n  \"a\": 0.1,\n  \"oauthAccount\": {\"emailAddress\": \"x@y.z\", \"n\": [1, {\"b\": \"}\\\"\"}]},\n  \"tail\": \"oauthAccount\"\n}\n"
        let out = try #require(JSONSplice.setting("oauthAccount", to: "{\"emailAddress\":\"new@y.z\"}", in: Data(text.utf8)))
        #expect(String(decoding: out, as: UTF8.self) == "{\n  \"a\": 0.1,\n  \"oauthAccount\": {\"emailAddress\":\"new@y.z\"},\n  \"tail\": \"oauthAccount\"\n}\n")
        let added = try #require(JSONSplice.setting("oauthAccount", to: "{}", in: Data("{\"a\": 1}".utf8)))
        #expect((try JSONSerialization.jsonObject(with: added) as? [String: Any])?.count == 2)
        let onEmpty = try #require(JSONSplice.setting("k", to: "1", in: Data("{}".utf8)))
        #expect((try JSONSerialization.jsonObject(with: onEmpty) as? [String: Any])?["k"] as? Int == 1)
        #expect(JSONSplice.setting("k", to: "1", in: Data("[1]".utf8)) == nil)
        #expect(JSONSplice.setting("k", to: "not json", in: Data("{}".utf8)) == nil)
    }
}

@Suite("Account vault", .serialized)
struct AccountVaultTests {
    @Test func adoptsClaudeSwapAccountsWithoutLoggingInAgain() throws {
        let box = try VaultSandbox()
        let live = VaultSandbox.login("one-live", expiresIn: 7200)
        try box.logIn("one@example.com", org: "o1", credentials: live)
        try box.installClaudeSwap([(1, "one@example.com", "o1", VaultSandbox.login("one-stale", expiresIn: 60)),
                                   (2, "two@example.com", "o2", VaultSandbox.login("two")),
                                   (3, "three@example.com", "o3", nil)], active: 1)
        #expect(box.vault.legacyAccountCount == 3)
        let report = box.vault.importFromClaudeSwap()
        #expect(report.imported == ["one@example.com", "two@example.com"])
        #expect(report.failed == ["three@example.com"])
        let accounts = box.vault.accounts()
        #expect(accounts.map(\.email) == ["one@example.com", "two@example.com"])
        // The account in use takes the login in use, not claude-swap's older copy.
        #expect(ClaudeCredential.accessToken(box.vault.credentials(for: accounts[0])) == "access-one-live")
        #expect(ClaudeCredential.accessToken(box.vault.credentials(for: accounts[1])) == "access-two")
        #expect(box.vault.activeAccount()?.email == "one@example.com")
        // The index holds no secret, and claude-swap's own copies are untouched.
        let index = try String(contentsOf: box.vault.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!index.contains("access-") && !index.contains("refresh-"))
        #expect(ClaudeCredential.accessToken(try box.keychain.get(service: "claude-swap", account: "account-1-one@example.com")) == "access-one-stale")
        // Running it again changes nothing.
        let again = box.vault.importFromClaudeSwap()
        #expect(again.imported.isEmpty && again.alreadyThere.count == 2)
        #expect(box.vault.accounts().count == 2)
    }

    @Test func switchesAndSwitchesBackKeepingEveryLogin() throws {
        let box = try VaultSandbox()
        let shared: [String: Any] = ["mcpOAuth": ["server": "token-of-this-mac"]]
        try box.logIn("one@example.com", org: "o1", credentials: VaultSandbox.login("one", extra: shared))
        try box.installClaudeSwap([(1, "one@example.com", "o1", nil), (2, "two@example.com", "o2", VaultSandbox.login("two", extra: ["mcpOAuth": ["server": "old"]]))], active: 1)
        _ = box.vault.importFromClaudeSwap()
        let accounts = box.vault.accounts()
        let before = try Data(contentsOf: URL(fileURLWithPath: box.home + "/.claude.json"))

        try box.vault.switchClaude(to: accounts[1].id)
        let live = box.vault.liveCredentials()
        #expect(ClaudeCredential.accessToken(live) == "access-two")
        // Machine-wide logins stay with the machine.
        #expect((ClaudeCredential.object(live)?["mcpOAuth"] as? [String: String]) == ["server": "token-of-this-mac"])
        let config = try box.config()
        #expect((config["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "two@example.com")
        #expect(config["numStartups"] as? Int == 42 && (config["projects"] as? [String: Any])?.count == 1)
        // Everything outside the account block is byte-identical.
        let after = try Data(contentsOf: URL(fileURLWithPath: box.home + "/.claude.json"))
        let restored = try #require(JSONSplice.setting("oauthAccount", to: accounts[0].profileJSON ?? "", in: after))
        let original = try #require(JSONSplice.setting("oauthAccount", to: accounts[0].profileJSON ?? "", in: before))
        #expect(restored == original)
        #expect(box.vault.activeAccount()?.email == "two@example.com")
        // The outgoing login was saved, and claude-swap was told which account is in use.
        #expect(ClaudeCredential.accessToken(box.vault.credentials(for: accounts[0])) == "access-one")
        let sequence = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: box.home + "/.claude-swap-backup/sequence.json"))) as? [String: Any]
        #expect(sequence?["activeAccountNumber"] as? Int == 2)
        // No lock is left behind.
        #expect(!FileManager.default.fileExists(atPath: box.home + "/.claude.lock") && !FileManager.default.fileExists(atPath: box.home + "/.claude.json.lock"))

        try box.vault.switchClaude(to: accounts[0].id)
        #expect(ClaudeCredential.accessToken(box.vault.liveCredentials()) == "access-one")
        #expect(box.vault.activeAccount()?.email == "one@example.com")
    }

    @Test func aLoginThatWasNeverSavedIsKeptWhenSwitchingAway() throws {
        let box = try VaultSandbox()
        try box.logIn("two@example.com", org: "o2", credentials: VaultSandbox.login("two"))
        let two = try box.vault.addCurrent()
        try box.logIn("fresh@example.com", org: "o9", credentials: VaultSandbox.login("fresh"))
        try box.vault.switchClaude(to: two.id)
        let saved = try #require(box.vault.accounts().first { $0.email == "fresh@example.com" })
        #expect(ClaudeCredential.accessToken(box.vault.credentials(for: saved)) == "access-fresh")
    }

    @Test func aFailedSwitchLeavesTheLoginInUseUntouched() throws {
        let box = try VaultSandbox()
        try box.logIn("one@example.com", org: "o1", credentials: VaultSandbox.login("one"))
        let one = try box.vault.addCurrent()
        try box.logIn("two@example.com", org: "o2", credentials: VaultSandbox.login("two"))
        _ = try box.vault.addCurrent()
        // A config Claude Code could not read either: the switch must refuse and change nothing.
        try "not json".write(toFile: box.home + "/.claude.json", atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try box.vault.switchClaude(to: one.id) }
        #expect(ClaudeCredential.accessToken(box.vault.liveCredentials()) == "access-two")
        // An account whose saved login is gone cannot be switched to.
        try box.keychain.delete(service: AccountVault.service, account: box.vault.slot(one))
        try box.logIn("two@example.com", org: "o2", credentials: VaultSandbox.login("two"))
        #expect(throws: AccountVaultError.self) { try box.vault.switchClaude(to: one.id) }
        #expect(ClaudeCredential.accessToken(box.vault.liveCredentials()) == "access-two")
    }

    @Test func aRefreshOfTheAccountInUseReachesClaudeCode() throws {
        let box = try VaultSandbox()
        try box.logIn("one@example.com", org: "o1", credentials: VaultSandbox.login("one", expiresIn: 100))
        let one = try box.vault.addCurrent()
        let saved = try #require(box.vault.credentials(for: one))
        let refreshed = try #require(ClaudeCredential.applyingRefresh(saved, response: ["access_token": "access-new", "refresh_token": "refresh-new", "expires_in": 28_800]))
        try box.vault.commitRefresh(refreshed, for: one.id)
        #expect(ClaudeCredential.accessToken(box.vault.liveCredentials()) == "access-new")
        #expect(ClaudeCredential.accessToken(box.vault.credentials(for: one)) == "access-new")
        #expect(!ClaudeCredential.isExpired(refreshed) && ClaudeCredential.isExpired(VaultSandbox.login("x", expiresIn: 100)))
    }

    @Test func renamesReordersAndRemoves() throws {
        let box = try VaultSandbox()
        try box.logIn("one@example.com", org: "o1", credentials: VaultSandbox.login("one"))
        let one = try box.vault.addCurrent()
        try box.logIn("two@example.com", org: "o2", credentials: VaultSandbox.login("two"))
        let two = try box.vault.addCurrent()
        #expect(try box.vault.addCurrent().id == two.id)
        box.vault.rename(one.id, alias: "  Trabajo ")
        box.vault.move(two.id, by: -1)
        #expect(box.vault.accounts().map(\.email) == ["two@example.com", "one@example.com"])
        #expect(box.vault.accounts().last?.alias == "Trabajo")
        try box.vault.remove(one.id)
        #expect(box.vault.accounts().count == 1)
        #expect(!box.keychain.exists(service: AccountVault.service, account: box.vault.slot(one)))
    }

    @Test func waitsForClaudeCodeLocksAndTakesOverDeadOnes() throws {
        let box = try VaultSandbox()
        let path = box.home + "/.claude.lock"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        #expect(throws: ClaudeLocks.Timeout.self) { try ClaudeLocks.with([(path, 60)], timeout: 0.4) {} }
        // A holder that died long ago does not block anybody.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: path)
        #expect(try ClaudeLocks.with([(path, 60)], timeout: 0.4) { 7 } == 7)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Suite("Claude usage")
struct ClaudeUsageTests {
    @Test func parsesWindowsAndPerModelLimits() {
        let body = #"{"five_hour":{"utilization":64.0,"resets_at":"2026-11-13T18:00:00.123456+00:00"},"seven_day":{"utilization":38,"resets_at":"2026-11-17T09:00:00Z"},"extra_usage":{"is_enabled":false},"limits":[{"kind":"weekly_scoped","percent":22,"resets_at":"2026-11-17T09:00:00Z","scope":{"model":{"display_name":"Fable"}}},{"kind":"other","percent":5}]}"#
        let windows = ClaudeOAuth.parseUsage(Data(body.utf8))
        #expect(windows.map(\.name) == ["5 h", "7 días", "Fable"])
        #expect(windows.map(\.percent) == [64, 38, 22])
        #expect(windows.allSatisfy { $0.resetsAt != nil })
        #expect(ClaudeOAuth.parseUsage(Data("nope".utf8)).isEmpty)
    }

    @Test func projectsWhetherAWeeklyQuotaLasts() {
        let now = Date()
        // Three days in with 60 % used: gone before the reset. With 30 %: fine.
        let reset = now.addingTimeInterval(4 * 86_400)
        #expect(ClaudeOAuth.willLast(name: "7 días", percent: 60, resetsAt: reset, at: now) == false)
        #expect(ClaudeOAuth.willLast(name: "7 días", percent: 30, resetsAt: reset, at: now) == true)
        // Too early in the week, or the short window: no verdict.
        #expect(ClaudeOAuth.willLast(name: "7 días", percent: 10, resetsAt: now.addingTimeInterval(6.8 * 86_400), at: now) == nil)
        #expect(ClaudeOAuth.willLast(name: "5 h", percent: 90, resetsAt: now.addingTimeInterval(600), at: now) == nil)
    }

    @Test func nativeAccountsCarryTheirReadings() throws {
        let box = try VaultSandbox()
        try box.logIn("one@example.com", org: "o1", credentials: VaultSandbox.login("one"))
        let one = try box.vault.addCurrent()
        var reading = AccountUsage()
        reading.windows = [.init(name: "5 h", percent: 12, resetsAt: nil)]
        reading.fetchedAt = Date()
        let list = AgentAccounts.native(vault: box.vault, usage: [one.id: reading])
        #expect(list.count == 1 && list[0].active && list[0].vaultID == one.id && list[0].windows.first?.percent == 12)
    }
}

@Suite("Codex accounts", .serialized)
struct CodexVaultTests {
    static func auth(_ email: String, account: String) -> String {
        func part(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let token = part(["alg": "none"]) + "." + part(["email": email, "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]]) + ".sig"
        let object: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": token, "access_token": "access-\(email)", "refresh_token": "refresh-\(email)", "account_id": account],
                                     "last_refresh": "2026-11-13T00:00:00Z"]
        // Pretty-printed with a trailing line break, as Codex writes it.
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), as: UTF8.self) + "\n"
    }

    @Test func savesAndSwapsTheAuthFile() throws {
        let box = try VaultSandbox()
        let path = box.home + "/.codex/auth.json"
        try FileManager.default.createDirectory(atPath: box.home + "/.codex", withIntermediateDirectories: true)
        #expect(throws: AccountVaultError.self) { try box.vault.addCurrentCodex() }
        let first = Self.auth("one@example.com", account: "w1")
        try first.write(toFile: path, atomically: true, encoding: .utf8)
        let one = try box.vault.addCurrentCodex()
        #expect(one.email == "one@example.com" && one.organizationName == "plus")
        // Logged into another account that was never saved: switching away must keep it.
        let second = Self.auth("two@example.com", account: "w2")
        try second.write(toFile: path, atomically: true, encoding: .utf8)
        try box.vault.switchCodex(to: one.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == first)
        #expect(box.vault.activeCodexAccount()?.id == one.id)
        let two = try #require(box.vault.accounts().first { $0.email == "two@example.com" })
        try box.vault.switchCodex(to: two.id)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == second)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        // The index never holds a token, and Claude Code's accounts are a separate list.
        let index = try String(contentsOf: box.vault.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!index.contains("access-") && !index.contains("refresh-"))
        #expect(AgentAccounts.native(vault: box.vault, usage: [:]).isEmpty)
    }
}

@Suite("Account switch suggestion")
struct AccountSuggestionTests {
    static func account(_ email: String, active: Bool, _ percents: [Double], read: TimeInterval = 60, note: String? = nil) -> AgentAccount {
        var account = AgentAccount(agent: "Claude Code", email: email, active: active)
        account.vaultID = email
        account.windows = percents.enumerated().map { UsageWindow(name: $0.offset == 0 ? "5 h" : "7 días", percent: $0.element, resetsAt: Date().addingTimeInterval(3600)) }
        account.usageFetched = Date().addingTimeInterval(-read)
        account.note = note
        return account
    }

    @Test func suggestsTheAccountWithMostRoomOnlyWhenItIsWorthIt() {
        var report = AccountsReport()
        report.accounts = [Self.account("a", active: true, [93, 40]), Self.account("b", active: false, [30, 55]), Self.account("c", active: false, [5, 20])]
        let suggestion = report.switchSuggestion(threshold: 90)
        #expect(suggestion?.to.email == "c" && suggestion?.window.name == "5 h")
        // An excluded account is never the destination: the next best one is.
        #expect(report.switchSuggestion(threshold: 90, excluded: ["c"])?.to.email == "b")
        // Below the threshold, or nobody with clear room, or only stale or failed readings: say nothing.
        report.accounts[0] = Self.account("a", active: true, [80, 40])
        #expect(report.switchSuggestion(threshold: 90) == nil)
        report.accounts = [Self.account("a", active: true, [95, 40]), Self.account("b", active: false, [30, 85]),
                           Self.account("c", active: false, [5, 5], read: 7200), Self.account("d", active: false, [5, 5], note: "sin conexión")]
        #expect(report.switchSuggestion(threshold: 90) == nil)
    }
}

@Suite("Account login")
struct AccountLoginTests {
    @Test func runsTheAgentsOwnLoginCommand() {
        let claude = AccountLogin.script(agent: "Claude Code", binaryPath: "/Users/o'brien/bin/claude")
        #expect(claude.hasPrefix("#!/bin/zsh -l\n"))
        #expect(claude.contains("'/Users/o'\\''brien/bin/claude' auth login\n"))
        #expect(AccountLogin.script(agent: "Codex", binaryPath: "/usr/local/bin/codex").contains("'/usr/local/bin/codex' login\n"))
    }
}

@Suite("Codex limits and session pace")
struct CodexLimitsTests {
    @Test func parsesTheAppServerAnswer() {
        let result: [String: Any] = ["rateLimits": ["planType": "plus", "primary": ["usedPercent": 2, "windowDurationMins": 300, "resetsAt": 1_794_629_199],
                                                    "secondary": ["usedPercent": 41.5, "resetsAt": 1_795_137_607], "credits": ["hasCredits": false, "unlimited": false]]]
        let plan = CodexLimits.parse(result)
        #expect(plan?.primaryUsedPercent == 2 && plan?.secondaryUsedPercent == 41.5 && plan?.planType == "plus")
        #expect(plan?.primaryResets == Date(timeIntervalSince1970: 1_794_629_199) && plan?.readAt != nil && plan?.credits == nil)
        #expect(CodexLimits.parse(["rateLimits": ["planType": "plus"]]) == nil)
        #expect(CodexLimits.parse([:]) == nil)
    }

    @Test func projectsWhenTheShortWindowRunsOut() {
        let now = Date()
        let reset = now.addingTimeInterval(2 * 3600)
        // 80 % after 3 h, and the last hour burned half of it: 40 points per hour, so 30 minutes are left.
        let out = SessionPace.runsOut(percent: 80, resetsAt: reset, windowTokens: 1000, lastHourTokens: 500, now: now)
        #expect(out.map { Int($0.timeIntervalSince(now) / 60) } == 30)
        // A quiet last hour reaches the reset; nothing to warn about. Right after a reset: nothing either.
        #expect(SessionPace.runsOut(percent: 80, resetsAt: reset, windowTokens: 1000, lastHourTokens: 50, now: now) == nil)
        #expect(SessionPace.runsOut(percent: 20, resetsAt: now.addingTimeInterval(4.95 * 3600), windowTokens: 10, lastHourTokens: 10, now: now) == nil)
    }

    @Test func oldReadingsAreStale() {
        var account = AgentAccount(agent: "Codex", email: "a", active: true)
        account.windows = [UsageWindow(name: "5 h", percent: 10, resetsAt: nil)]
        account.usageFetched = Date().addingTimeInterval(-3600)
        #expect(account.isStale())
        account.usageFetched = Date()
        #expect(!account.isStale())
    }
}
