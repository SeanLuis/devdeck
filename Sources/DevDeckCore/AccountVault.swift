import Foundation

/// A login DevDeck keeps so it can be put back in use later. The index entry holds nothing secret;
/// the credentials live in the keychain under `AccountVault.service`.
public struct StoredAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var agent: String
    public var email: String
    public var organizationUuid: String?
    public var organizationName: String?
    /// Name the user gave it.
    public var alias: String?
    public var addedAt: Date
    /// The agent's own description of the account (`oauthAccount` of `~/.claude.json`), as JSON text. Not secret.
    public var profileJSON: String?
    /// Where claude-swap keeps its copy of this login, when the account was adopted from it.
    public var legacySlot: String?
    public var legacyNumber: Int?

    public init(id: String = UUID().uuidString, agent: String, email: String, organizationUuid: String? = nil, organizationName: String? = nil,
                alias: String? = nil, addedAt: Date = Date(), profileJSON: String? = nil, legacySlot: String? = nil, legacyNumber: Int? = nil) {
        self.id = id; self.agent = agent; self.email = email; self.organizationUuid = organizationUuid
        self.organizationName = organizationName; self.alias = alias; self.addedAt = addedAt
        self.profileJSON = profileJSON; self.legacySlot = legacySlot; self.legacyNumber = legacyNumber
    }

    /// Claude Code's id of the account (`accountUuid` of its `oauthAccount` block), when it was saved.
    public var accountUuid: String? {
        guard let data = profileJSON?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = object["accountUuid"] as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    /// Same person in the same organization = same account.
    public func matches(email other: String, organization: String?) -> Bool {
        email.caseInsensitiveCompare(other) == .orderedSame && (organizationUuid ?? "") == (organization ?? "")
    }
}

public enum AccountVaultError: LocalizedError {
    case notLoggedIn
    case unknownAccount
    case missingCredentials(String)
    case unreadableConfig
    case writeNotVerified

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return L("Claude Code no tiene ninguna sesión iniciada.")
        case .unknownAccount: return L("Esa cuenta ya no está guardada.")
        case .missingCredentials(let email): return L("No hay credenciales guardadas para %@. Inicia sesión con esa cuenta y vuelve a añadirla.", email)
        case .unreadableConfig: return L("No se pudo leer la configuración de Claude Code.")
        case .writeNotVerified: return L("El cambio no se pudo verificar y se deshizo.")
        }
    }
}

public struct AccountImportReport: Sendable {
    public var imported: [String] = []
    public var alreadyThere: [String] = []
    /// Accounts whose saved login could not be read.
    public var failed: [String] = []
    public init() {}
}

/// Helpers over the credential JSON Claude Code stores: `{"claudeAiOauth": {accessToken, refreshToken, expiresAt…}, …}`.
/// Values are never logged or returned in error messages.
public enum ClaudeCredential {
    /// Siblings of the login that belong to the machine, not to an account (MCP logins, plugin secrets):
    /// on a switch the copy in use stays.
    static let sharedKeys = ["mcpOAuth", "mcpOAuthClientConfig", "mcpXaaIdp", "mcpXaaIdpConfig", "pluginSecrets"]

    static func object(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func oauth(_ json: String?) -> [String: Any]? { object(json)?["claudeAiOauth"] as? [String: Any] }

    public static func isLogin(_ json: String?) -> Bool { (oauth(json)?["accessToken"] as? String)?.isEmpty == false }

    public static func accessToken(_ json: String?) -> String? { oauth(json)?["accessToken"] as? String }

    static func refreshToken(_ json: String?) -> String? { oauth(json)?["refreshToken"] as? String }

    /// Two copies of the same login generation: they hold the same refresh token. Only one holder may ever renew
    /// it, because a renewal spends that token for every other copy.
    public static func sameGeneration(_ a: String?, _ b: String?) -> Bool {
        guard let token = refreshToken(a), !token.isEmpty else { return false }
        return token == refreshToken(b)
    }

    /// When the access token stops working.
    public static func expiresAt(_ json: String?) -> Date? {
        (oauth(json)?["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    public static func isExpired(_ json: String?, now: Date = Date(), margin: TimeInterval = 300) -> Bool {
        guard let expires = expiresAt(json) else { return false }
        return now.addingTimeInterval(margin) >= expires
    }

    /// When the login itself lapses (`refreshTokenExpiresAt`): past it only a new /login brings the account back.
    /// The access token's `expiresAt` is a different thing, renewed every few hours. nil for logins older than the field.
    public static func loginExpiresAt(_ json: String?) -> Date? {
        guard let value = (oauth(json)?["refreshTokenExpiresAt"] as? NSNumber)?.doubleValue, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    public static func isLoginExpired(_ json: String?, now: Date = Date()) -> Bool {
        loginExpiresAt(json).map { $0 <= now } ?? false
    }

    /// The account the login was issued to, when Claude Code recorded it in the credential.
    public static func accountUuid(_ json: String?) -> String? {
        (oauth(json)?["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Two copies of the same login lineage: the same refresh token, or the same login stamp to the millisecond.
    /// A renewal changes the refresh token but keeps `refreshTokenExpiresAt`, so the stamp follows a login
    /// across renewals: two different accounts never share it.
    public static func sameLineage(_ a: String?, _ b: String?) -> Bool {
        if sameGeneration(a, b) { return true }
        guard let x = (oauth(a)?["refreshTokenExpiresAt"] as? NSNumber)?.int64Value,
              let y = (oauth(b)?["refreshTokenExpiresAt"] as? NSNumber)?.int64Value else { return false }
        return x > 0 && x == y
    }

    static func serialize(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// The target login with the machine-wide fields of the credentials in use.
    public static func mergingShared(target: String, live: String?) -> String {
        guard var object = object(target), object["claudeAiOauth"] != nil else { return target }
        let liveObject = self.object(live)
        for key in sharedKeys {
            if let liveObject { object[key] = liveObject[key] }   // absent in use = absent after the switch
        }
        return serialize(object) ?? target
    }

    /// The newer of two copies of the same login (a refresh moves `expiresAt` forward).
    static func fresher(_ a: String?, _ b: String?) -> String? {
        guard isLogin(a) else { return isLogin(b) ? b : (a ?? b) }
        guard isLogin(b) else { return a }
        return (expiresAt(b) ?? .distantPast) > (expiresAt(a) ?? .distantPast) ? b : a
    }

    /// `credentials` after a token refresh answered with `response`.
    public static func applyingRefresh(_ credentials: String, response: [String: Any], now: Date = Date()) -> String? {
        guard var object = object(credentials), var oauth = object["claudeAiOauth"] as? [String: Any],
              let access = response["access_token"] as? String, let seconds = (response["expires_in"] as? NSNumber)?.doubleValue else { return nil }
        oauth["accessToken"] = access
        oauth["expiresAt"] = Int((now.timeIntervalSince1970 + seconds) * 1000)
        if let refresh = response["refresh_token"] as? String, !refresh.isEmpty { oauth["refreshToken"] = refresh }
        if let scope = response["scope"] as? String, !scope.isEmpty { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        object["claudeAiOauth"] = oauth
        return serialize(object)
    }
}

/// Replaces one top-level value of a JSON document without re-encoding the rest of it.
/// `~/.claude.json` is large and rewritten by every open session; only the account block should change.
public enum JSONSplice {
    /// Byte range of the value of top-level `key`, or nil.
    static func valueRange(of key: String, in bytes: [UInt8]) -> Range<Int>? {
        var index = 0
        let count = bytes.count
        func skipSpace() { while index < count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
        func skipString() -> Range<Int>? {
            guard index < count, bytes[index] == 0x22 else { return nil }
            let start = index
            index += 1
            while index < count {
                if bytes[index] == 0x5C { index += 2; continue }
                if bytes[index] == 0x22 { index += 1; return start..<index }
                index += 1
            }
            return nil
        }
        func skipValue() -> Bool {
            skipSpace()
            guard index < count else { return false }
            switch bytes[index] {
            case 0x22: return skipString() != nil
            case 0x7B, 0x5B:
                var depth = 0
                while index < count {
                    switch bytes[index] {
                    case 0x22: if skipString() == nil { return false }; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { index += 1; return true }
                    default: break
                    }
                    index += 1
                }
                return false
            default:
                while index < count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                return true
            }
        }
        skipSpace()
        guard index < count, bytes[index] == 0x7B else { return nil }
        index += 1
        let wanted = Array(("\"" + key + "\"").utf8)
        while true {
            skipSpace()
            guard index < count, bytes[index] != 0x7D, let name = skipString() else { return nil }
            skipSpace()
            guard index < count, bytes[index] == 0x3A else { return nil }
            index += 1
            skipSpace()
            let start = index
            guard skipValue() else { return nil }
            if Array(bytes[name]) == wanted { return start..<index }
            skipSpace()
            guard index < count, bytes[index] == 0x2C else { return nil }
            index += 1
        }
    }

    /// `document` with top-level `key` set to `value` (JSON text). Adds the key when it is missing.
    public static func setting(_ key: String, to value: String, in document: Data) -> Data? {
        let bytes = [UInt8](document)
        guard (try? JSONSerialization.jsonObject(with: document)) is [String: Any] else { return nil }
        var out: [UInt8]
        if let range = valueRange(of: key, in: bytes) {
            out = Array(bytes[..<range.lowerBound]) + Array(value.utf8) + Array(bytes[range.upperBound...])
        } else {
            guard let open = bytes.firstIndex(of: 0x7B) else { return nil }
            let rest = bytes[(open + 1)...]
            let empty = rest.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } == 0x7D
            out = Array(bytes[...open]) + Array(("\n  \"" + key + "\": " + value + (empty ? "\n" : ",")).utf8) + Array(rest)
        }
        let data = Data(out)
        // Never hand back something that stopped being a JSON object.
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        return data
    }
}

/// DevDeck's own account store for Claude Code: several logins kept in the keychain, one of them in use.
///
/// The login in use is Claude Code's keychain item plus the `oauthAccount` block of `~/.claude.json`;
/// switching means saving both for the outgoing account and putting the target's in their place.
/// Every path is injectable so tests run against a throwaway keychain and a fake home folder.
public final class AccountVault: @unchecked Sendable {
    public static let service = "dev.devdeck.accounts"
    public static let claudeService = "Claude Code-credentials"
    static let legacyService = "claude-swap"
    public static let claude = "Claude Code"

    public let home: String
    public let directory: URL
    public let keychain: Keychain
    /// Account name of Claude Code's keychain item: the login name, as Claude Code computes it.
    public let user: String
    let lock = NSRecursiveLock()

    public init(home: String = NSHomeDirectory(), directory: URL, keychain: Keychain = Keychain(), user: String? = nil) {
        self.home = home
        self.directory = directory
        self.keychain = keychain
        self.user = user ?? ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    // MARK: Index

    private var indexURL: URL { directory.appendingPathComponent("accounts.json") }

    public func accounts() -> [StoredAccount] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredAccount].self, from: data)) ?? []
    }

    func save(_ accounts: [StoredAccount]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    public func rename(_ id: String, alias: String?) {
        lock.lock(); defer { lock.unlock() }
        var list = accounts()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        list[index].alias = trimmed?.isEmpty == false ? trimmed : nil
        save(list)
    }

    public func move(_ id: String, by offset: Int) {
        lock.lock(); defer { lock.unlock() }
        var list = accounts()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + offset, 0), list.count - 1)
        guard target != index else { return }
        list.insert(list.remove(at: index), at: target)
        save(list)
    }

    /// Forgets a saved login. The login in use is left alone: Claude Code keeps working with it.
    public func remove(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var list = accounts()
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        try keychain.delete(service: Self.service, account: slot(list[index]))
        list.remove(at: index)
        save(list)
    }

    // MARK: Credentials of a saved account

    func slot(_ account: StoredAccount) -> String { "\(account.agent)|\(account.id)" }

    /// The saved login of an account: DevDeck's copy, or claude-swap's when that one is newer
    /// (it refreshes tokens too while it is still installed).
    public func credentials(for account: StoredAccount) -> String? {
        lock.lock(); defer { lock.unlock() }
        let own = try? keychain.get(service: Self.service, account: slot(account))
        guard let legacySlot = account.legacySlot, let legacy = try? keychain.get(service: Self.legacyService, account: legacySlot) else { return own }
        return ClaudeCredential.fresher(own, legacy)
    }

    /// Saves a login for an account, and keeps claude-swap's copy in step while it exists, so neither store
    /// is left holding a refresh token the other already spent.
    public func store(_ credentials: String, for account: StoredAccount) throws {
        lock.lock(); defer { lock.unlock() }
        try keychain.set(service: Self.service, account: slot(account), secret: credentials)
        if let legacySlot = account.legacySlot, keychain.exists(service: Self.legacyService, account: legacySlot) {
            try? keychain.set(service: Self.legacyService, account: legacySlot, secret: credentials)
        }
    }

    /// The saved account a login provably belongs to, judged on this Mac without asking anyone: the account id
    /// Claude Code wrote into the credential, else the one saved account that holds the same login lineage.
    /// nil when it cannot be told (or more than one account claims it).
    public func owner(of credentials: String?, in list: [StoredAccount]? = nil) -> StoredAccount? {
        let claude = (list ?? accounts()).filter { $0.agent == Self.claude }
        if let uuid = ClaudeCredential.accountUuid(credentials) {
            return claude.first { $0.accountUuid == uuid }
        }
        let lineage = claude.filter { ClaudeCredential.sameLineage(self.credentials(for: $0), credentials) }
        return lineage.count == 1 ? lineage[0] : nil
    }

    // MARK: The login in use

    /// Claude Code's config file: the legacy `~/.claude/.config.json` when it is in use, else `~/.claude.json`.
    public var configPath: String {
        let legacy = home + "/.claude/.config.json"
        if let size = (try? FileManager.default.attributesOfItem(atPath: legacy))?[.size] as? NSNumber, size.intValue > 0 { return legacy }
        return home + "/.claude.json"
    }

    public struct LiveIdentity: Hashable, Sendable {
        public let email: String
        public let organizationUuid: String?
        public let organizationName: String?
        public let profileJSON: String
    }

    /// Who Claude Code says is logged in.
    public func liveIdentity() -> LiveIdentity? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any], let email = account["emailAddress"] as? String,
              let profile = ClaudeCredential.serialize(account) else { return nil }
        return LiveIdentity(email: email, organizationUuid: account["organizationUuid"] as? String,
                            organizationName: account["organizationName"] as? String, profileJSON: profile)
    }

    public func liveCredentials() -> String? {
        try? keychain.get(service: Self.claudeService, account: user)
    }

    /// The saved account that is in use right now, if it is one of them.
    public func activeAccount() -> StoredAccount? {
        guard let live = liveIdentity() else { return nil }
        return accounts().first { $0.agent == Self.claude && $0.matches(email: live.email, organization: live.organizationUuid) }
    }

    /// Saves the login Claude Code is using now as an account (or refreshes its saved copy).
    @discardableResult
    public func addCurrent() throws -> StoredAccount {
        lock.lock(); defer { lock.unlock() }
        guard let live = liveIdentity(), let credentials = liveCredentials(), ClaudeCredential.isLogin(credentials) else { throw AccountVaultError.notLoggedIn }
        var list = accounts()
        var account: StoredAccount
        if let index = list.firstIndex(where: { $0.agent == Self.claude && $0.matches(email: live.email, organization: live.organizationUuid) }) {
            list[index].profileJSON = live.profileJSON
            list[index].organizationName = live.organizationName
            account = list[index]
        } else {
            account = StoredAccount(agent: Self.claude, email: live.email, organizationUuid: live.organizationUuid,
                                    organizationName: live.organizationName, profileJSON: live.profileJSON)
            list.append(account)
        }
        try store(credentials, for: account)
        save(list)
        return account
    }

    // MARK: Adopting claude-swap's accounts

    var legacyRoot: String { home + "/.claude-swap-backup" }

    public var legacyAccountCount: Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyRoot + "/sequence.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return (root["accounts"] as? [String: Any])?.count ?? 0
    }

    /// claude-swap accounts that are not in DevDeck's store yet.
    public var adoptableCount: Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyRoot + "/sequence.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registry = root["accounts"] as? [String: Any] else { return 0 }
        let own = accounts().filter { $0.agent == Self.claude }
        return registry.values.filter { value in
            guard let entry = value as? [String: Any], let email = entry["email"] as? String else { return false }
            return !own.contains { $0.matches(email: email, organization: entry["organizationUuid"] as? String) }
        }.count
    }

    /// What an import would find, without writing anything: each account and whether its saved login can be read.
    public func legacyPreview() -> [(number: Int, email: String, readable: Bool, tokenExpires: Date?)] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyRoot + "/sequence.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registry = root["accounts"] as? [String: Any] else { return [] }
        return registry.keys.compactMap(Int.init).sorted().compactMap { number in
            guard let email = (registry[String(number)] as? [String: Any])?["email"] as? String else { return nil }
            let saved = (try? keychain.get(service: Self.legacyService, account: "account-\(number)-\(email)")) ?? legacyFileCredentials(number: number, email: email)
            return (number, email, ClaudeCredential.isLogin(saved), ClaudeCredential.expiresAt(saved))
        }
    }

    /// Copies every account claude-swap manages into DevDeck's store, without logging in again and without
    /// touching claude-swap's own data. Safe to run more than once.
    public func importFromClaudeSwap() -> AccountImportReport {
        lock.lock(); defer { lock.unlock() }
        var report = AccountImportReport()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: legacyRoot + "/sequence.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let registry = root["accounts"] as? [String: Any] else { return report }
        let order = (root["sequence"] as? [NSNumber])?.map(\.intValue) ?? registry.keys.compactMap(Int.init).sorted()
        let live = liveIdentity()
        var list = accounts()
        for number in order {
            guard let entry = registry[String(number)] as? [String: Any], let email = entry["email"] as? String else { continue }
            let organization = entry["organizationUuid"] as? String
            let legacySlot = "account-\(number)-\(email)"
            let isLive = live.map { $0.email.caseInsensitiveCompare(email) == .orderedSame && ($0.organizationUuid ?? "") == (organization ?? "") } ?? false
            // The login in use is the authority for its account: its saved copy can be a refresh behind.
            var credentials = isLive ? liveCredentials() : nil
            if !ClaudeCredential.isLogin(credentials) { credentials = try? keychain.get(service: Self.legacyService, account: legacySlot) }
            if !ClaudeCredential.isLogin(credentials) { credentials = legacyFileCredentials(number: number, email: email) }
            var profile = isLive ? live?.profileJSON : nil
            if profile == nil, let config = try? Data(contentsOf: URL(fileURLWithPath: legacyRoot + "/configs/.claude-config-\(number)-\(email).json")),
               let object = try? JSONSerialization.jsonObject(with: config) as? [String: Any], let block = object["oauthAccount"] as? [String: Any] {
                profile = ClaudeCredential.serialize(block)
            }
            guard let credentials, ClaudeCredential.isLogin(credentials), let profile else { report.failed.append(email); continue }

            var account: StoredAccount
            if let index = list.firstIndex(where: { $0.agent == Self.claude && $0.matches(email: email, organization: organization) }) {
                list[index].legacySlot = legacySlot
                list[index].legacyNumber = number
                if list[index].profileJSON == nil { list[index].profileJSON = profile }
                account = list[index]
                report.alreadyThere.append(email)
            } else {
                account = StoredAccount(agent: Self.claude, email: email, organizationUuid: organization,
                                        organizationName: entry["organizationName"] as? String, profileJSON: profile,
                                        legacySlot: legacySlot, legacyNumber: number)
                list.append(account)
                report.imported.append(email)
            }
            // Keep whichever copy is newer; never replace a newer login with an older one.
            let own = try? keychain.get(service: Self.service, account: slot(account))
            guard let best = ClaudeCredential.fresher(credentials, own) else { continue }
            do { try keychain.set(service: Self.service, account: slot(account), secret: best) }
            catch {
                list.removeAll { $0.id == account.id && report.imported.contains(email) }
                report.imported.removeAll { $0 == email }
                report.failed.append(email)
            }
        }
        save(list)
        return report
    }

    /// claude-swap's file fallback: the login, base64-encoded.
    private func legacyFileCredentials(number: Int, email: String) -> String? {
        guard let text = try? String(contentsOfFile: legacyRoot + "/credentials/.creds-\(number)-\(email).enc", encoding: .utf8),
              let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Switching

    /// Makes `id` the account Claude Code uses. The outgoing login is saved first; if any step cannot be
    /// verified, the previous login is put back.
    public func switchClaude(to id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var list = accounts()
        guard let target = list.first(where: { $0.id == id && $0.agent == Self.claude }) else { throw AccountVaultError.unknownAccount }
        guard let targetCredentials = credentials(for: target), ClaudeCredential.isLogin(targetCredentials), let profile = target.profileJSON else {
            throw AccountVaultError.missingCredentials(target.email)
        }
        let config = configPath
        try ClaudeLocks.with(ClaudeLocks.credentialLocks(home: home) + [ClaudeLocks.configLock(configPath: config)]) {
            let liveCredentials = self.liveCredentials()
            let live = liveIdentity()
            if let live, live.email.caseInsensitiveCompare(target.email) == .orderedSame, (live.organizationUuid ?? "") == (target.organizationUuid ?? "") { return }

            // 1. Nothing is lost: the login in use goes to its account's slot (a new one if it was never saved).
            if let live, let liveCredentials, ClaudeCredential.isLogin(liveCredentials) {
                var outgoing: StoredAccount
                if let index = list.firstIndex(where: { $0.agent == Self.claude && $0.matches(email: live.email, organization: live.organizationUuid) }) {
                    list[index].profileJSON = live.profileJSON
                    outgoing = list[index]
                } else {
                    outgoing = StoredAccount(agent: Self.claude, email: live.email, organizationUuid: live.organizationUuid,
                                             organizationName: live.organizationName, profileJSON: live.profileJSON)
                    list.append(outgoing)
                }
                // The config names one account, but a session that was still open after the last switch may have
                // renewed the previous account's login and written it back: then the login in use is that other
                // account's, and filing it under the config's name would leave this slot holding someone else's login.
                if let owner = owner(of: liveCredentials, in: list), owner.id != outgoing.id {
                    outgoing = owner
                }
                // The saved copy can be the newer one (a renewal that could not reach the login in use): never go back.
                let saved = credentials(for: outgoing)
                if !ClaudeCredential.isLogin(saved) || ClaudeCredential.fresher(saved, liveCredentials) != saved { try store(liveCredentials, for: outgoing) }
                save(list)
            }

            // 2. The config with the target's account block, built before anything is written.
            guard let original = try? Data(contentsOf: URL(fileURLWithPath: config)),
                  let updated = JSONSplice.setting("oauthAccount", to: profile, in: original) else { throw AccountVaultError.unreadableConfig }

            // 3. Credentials first, then the config; undo the credentials if the config cannot be written.
            let incoming = ClaudeCredential.mergingShared(target: targetCredentials, live: liveCredentials)
            let permissions = (try? FileManager.default.attributesOfItem(atPath: config))?[.posixPermissions]
            do {
                try keychain.set(service: Self.claudeService, account: user, secret: incoming)
                try updated.write(to: URL(fileURLWithPath: config), options: .atomic)
                if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: config) }
                guard liveIdentity()?.email.caseInsensitiveCompare(target.email) == .orderedSame else { throw AccountVaultError.writeNotVerified }
            } catch {
                // Back to exactly what was there: the previous login, or no login at all — never the target's
                // credentials under the previous account's name.
                if let liveCredentials { try? keychain.set(service: Self.claudeService, account: user, secret: liveCredentials) }
                else { try? keychain.delete(service: Self.claudeService, account: user) }
                try? original.write(to: URL(fileURLWithPath: config), options: .atomic)
                if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: config) }
                throw error
            }
            noteLegacyActive(target)
        }
    }

    /// Tells claude-swap (while it is still installed) which of its accounts is in use, so it does not
    /// file the new login under the old account the next time it runs.
    private func noteLegacyActive(_ account: StoredAccount) {
        guard let number = account.legacyNumber else { return }
        let url = URL(fileURLWithPath: legacyRoot + "/sequence.json")
        guard let data = try? Data(contentsOf: url),
              let updated = JSONSplice.setting("activeAccountNumber", to: String(number), in: data) else { return }
        try? updated.write(to: url, options: .atomic)
    }

    /// Records a renewed login. `spent` is the copy that was renewed: if Claude Code holds that same generation
    /// (the account became the one in use meanwhile, or its config could not be read), the login in use is
    /// updated too, or Claude Code would be left with a spent refresh token and ask to log in again.
    public func commitRefresh(_ credentials: String, for id: String, spent: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard let account = accounts().first(where: { $0.id == id }) else { return }
        try store(credentials, for: account)
        guard let spent, ClaudeCredential.sameGeneration(liveCredentials(), spent) else { return }
        try ClaudeLocks.with(ClaudeLocks.credentialLocks(home: home)) {
            let current = liveCredentials()
            guard ClaudeCredential.sameGeneration(current, spent) else { return }
            try keychain.set(service: Self.claudeService, account: user, secret: ClaudeCredential.mergingShared(target: credentials, live: current))
        }
    }
}
