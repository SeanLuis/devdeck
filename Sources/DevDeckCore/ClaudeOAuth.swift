import Foundation

/// What an account's limits looked like the last time they were read.
public struct AccountUsage: Codable, Hashable, Sendable {
    public struct Window: Codable, Hashable, Sendable {
        public var name: String
        public var percent: Double
        public var resetsAt: Date?
    }

    public var windows: [Window] = []
    public var fetchedAt: Date?
    /// Why there is no fresh reading ("sesión caducada", "sin conexión"…).
    public var note: String?
    public init() {}

    /// Notes for a read that failed for a moment: the last good figures still stand while they are fresh.
    public static let transientNotes: Set<String> = ["sin conexión", "límite de consultas; se reintenta luego"]

    public func usageWindows(now: Date = Date()) -> [UsageWindow] {
        windows.map { UsageWindow(name: $0.name, percent: $0.percent, resetsAt: $0.resetsAt,
                                  willLast: ClaudeOAuth.willLast(name: $0.name, percent: $0.percent, resetsAt: $0.resetsAt, at: fetchedAt ?? now)) }
    }
}

/// The two calls DevDeck makes with an account's own token: read its usage, and renew an expired token.
/// Tokens go only to Anthropic's endpoints and are never written to logs.
public enum ClaudeOAuth {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id (the refresh must come from the client the token was issued to).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "DevDeck"

    public enum Failure: Error, Equatable {
        /// The token was refused: the login is expired or revoked.
        case unauthorized
        case rateLimited
        case network
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Response of the usage endpoint → the 5-hour window, the weekly one and one per model that has its own quota.
    public static func parseUsage(_ data: Data) -> [AccountUsage.Window] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var windows: [AccountUsage.Window] = []
        for (key, name) in [("five_hour", "5 h"), ("seven_day", "7 días")] {
            guard let window = root[key] as? [String: Any], let percent = (window["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(name: name, percent: percent, resetsAt: date(window["resets_at"])))
        }
        for limit in (root["limits"] as? [[String: Any]]) ?? [] {
            guard let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any], let name = model["display_name"] as? String,
                  !name.isEmpty, let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
            windows.append(.init(name: name, percent: percent, resetsAt: date(limit["resets_at"])))
        }
        return windows
    }

    /// False when, at the pace so far, a weekly quota runs out before it resets. nil when it is too early to say
    /// (the first day of the week) or the window is the short one.
    public static func willLast(name: String, percent: Double, resetsAt: Date?, at now: Date) -> Bool? {
        guard name != "5 h", let resetsAt else { return nil }
        let period: TimeInterval = 7 * 86_400
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = period - remaining
        guard remaining > 0, elapsed >= 86_400 else { return nil }
        return percent + percent / elapsed * remaining < 100
    }

    private static func send(_ request: URLRequest) async -> (Result<Data, Failure>, retryAfter: TimeInterval?) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            switch http?.statusCode ?? 0 {
            case 200..<300: return (.success(data), nil)
            case 400, 401, 403: return (.failure(.unauthorized), nil)
            case 429:
                let after = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                return (.failure(.rateLimited), after)
            default: return (.failure(.network), nil)
            }
        } catch {
            return (.failure(.network), nil)
        }
    }

    public static func usage(accessToken: String) async -> Result<[AccountUsage.Window], Failure> {
        return await usageReading(accessToken: accessToken).result
    }

    /// The usage reading, and how long the server asked to wait when it refused for too many requests.
    public static func usageReading(accessToken: String) async -> (result: Result<[AccountUsage.Window], Failure>, retryAfter: TimeInterval?) {
        var request = URLRequest(url: usageURL, timeoutInterval: 12)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (result, after) = await send(request)
        return (result.map(parseUsage), after)
    }

    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Whose login a token is, as Anthropic answers it.
    public struct Identity: Equatable, Sendable {
        public var uuid: String
        public var email: String?
        public var organizationUuid: String?
    }

    static func parseProfile(_ data: Data) -> Identity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let uuid = (account["uuid"] as? String)?.trimmingCharacters(in: .whitespaces), !uuid.isEmpty else { return nil }
        return Identity(uuid: uuid, email: account["email"] as? String,
                        organizationUuid: (root["organization"] as? [String: Any])?["uuid"] as? String)
    }

    /// The account a token belongs to. The credential alone cannot say it: the config can name one account while
    /// the credential store holds another's token.
    public static func profile(accessToken: String) async -> Result<Identity, Failure> {
        var request = URLRequest(url: profileURL, timeoutInterval: 12)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (result, _) = await send(request)
        switch result {
        case .success(let data): return parseProfile(data).map { .success($0) } ?? .failure(.network)
        case .failure(let failure): return .failure(failure)
        }
    }

    /// Renews the access token of a saved login. Returns the whole credential, ready to store.
    /// Only an explicit `invalid_grant` means the login is dead; any other refusal is treated as momentary.
    public static func refresh(credentials: String) async -> Result<String, Failure> {
        guard let refreshToken = ClaudeCredential.refreshToken(credentials), !refreshToken.isEmpty else { return .failure(.unauthorized) }
        var request = URLRequest(url: tokenURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure(refreshFailure(status: status, body: data)) }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let updated = ClaudeCredential.applyingRefresh(credentials, response: object) else { return .failure(.network) }
            return .success(updated)
        } catch {
            return .failure(.network)
        }
    }

    static func refreshFailure(status: Int, body: Data) -> Failure {
        if status == 429 { return .rateLimited }
        let error = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
        return (400..<500).contains(status) && error == "invalid_grant" ? .unauthorized : .network
    }
}

/// Reads the real limits of every saved account, a few minutes apart, and remembers the last reading.
public actor AccountUsageService {
    private var cache: [String: AccountUsage] = [:]
    private var lastAttempt: [String: Date] = [:]
    /// Renewed logins that could not be saved yet. A renewal spends the old refresh token, so these are
    /// the only valid copy until they reach the keychain: kept in memory and retried, never dropped.
    private var unsaved: [String: String] = [:]
    private let url: URL?
    // The usage endpoint allows each account roughly 28-30 requests in any trailing hour; past that it answers
    // "too many requests" until old requests age out, up to an hour later. Every interval below keeps an account
    // at 20 an hour or fewer, so the reading never goes stale when it matters most.
    /// Seconds between two readings of the same account.
    public var interval: TimeInterval = 300
    /// The account in use while the agent spends tokens.
    public var activeInterval: TimeInterval = 180
    /// The account in use while it climbs within ten points of the switch line: a short, self-limiting burst
    /// (it ends when the account is switched or stops climbing).
    public var urgentInterval: TimeInterval = 90
    /// Longest wait after the account keeps answering "too many requests".
    public var maxBackoff: TimeInterval = 3600
    /// Wait per account after a "too many requests" answer; doubles each time, cleared by a good read.
    private var backoff: [String: TimeInterval] = [:]
    /// When each account last answered "too many requests": for the next hour it is read more slowly.
    private var limitedAt: [String: Date] = [:]
    /// Whether the last good reading was higher than the one before.
    private var rising: [String: Bool] = [:]
    /// Renewals on the network. A second caller waits for the first: two renewals of one refresh token
    /// would leave one of them holding a spent token.
    private var renewing: [String: Task<Renewal, Never>] = [:]

    public enum Renewal: Equatable, Sendable {
        case renewed(String)
        /// Claude Code holds this same login generation: it renews it, never DevDeck.
        case inUse
        /// The login was refused for good: it needs a new sign-in.
        case dead
        /// No answer this time (network, rate limit); nothing changed.
        case unavailable
    }

    static let deadNote = "sesión caducada: vuelve a iniciar sesión"
    /// The slot holds a login that Anthropic says is another account's: its figures would be that account's.
    public static let foreignNote = "guarda el login de otra cuenta: vuelve a iniciar sesión en esta"

    /// What was learnt about whose login each account holds, per login generation (its refresh token), so the
    /// profile is asked once per renewal at most. In memory only.
    private var ownership: [String: (generation: Int, owner: ClaudeOAuth.Identity)] = [:]

    public enum Ownership: Equatable, Sendable {
        case own
        /// Anthropic says the token is another account's.
        case foreign(ClaudeOAuth.Identity)
        /// No answer (offline, refused, an account saved before its id was kept): taken as its own, as before.
        case unknown
    }

    static func judge(_ identity: ClaudeOAuth.Identity, uuid: String?, email: String) -> Ownership {
        if let uuid { return identity.uuid == uuid ? .own : .foreign(identity) }
        guard let seen = identity.email, !seen.isEmpty else { return .unknown }
        return seen.caseInsensitiveCompare(email) == .orderedSame ? .own : .foreign(identity)
    }

    /// Whether `credentials` really are the login of the account `key` names. Asks Anthropic once per generation.
    public func ownership(of key: String, uuid: String?, email: String, credentials: String?) async -> Ownership {
        guard let token = ClaudeCredential.accessToken(credentials), !ClaudeCredential.isExpired(credentials, margin: 0) else { return .unknown }
        let generation = (ClaudeCredential.refreshToken(credentials) ?? token).hashValue
        if let known = ownership[key], known.generation == generation { return Self.judge(known.owner, uuid: uuid, email: email) }
        guard case .success(let identity) = await ClaudeOAuth.profile(accessToken: token) else { return .unknown }
        ownership[key] = (generation, identity)
        return Self.judge(identity, uuid: uuid, email: email)
    }

    /// What is already known about whose login `credentials` are, without asking.
    func knownOwnership(of key: String, uuid: String?, email: String, credentials: String?) -> Ownership? {
        guard let known = ownership[key],
              known.generation == (ClaudeCredential.refreshToken(credentials) ?? ClaudeCredential.accessToken(credentials) ?? "").hashValue else { return nil }
        return Self.judge(known.owner, uuid: uuid, email: email)
    }

    /// Before a switch: whether the saved login of `account` is really that account's.
    public func verify(_ account: StoredAccount, vault: AccountVault) async -> Ownership {
        let credentials = unsaved[account.id] ?? vault.credentials(for: account)
        let verdict = await ownership(of: account.id, uuid: account.accountUuid, email: account.email, credentials: credentials)
        if case .foreign = verdict { markForeign(account.id) }
        return verdict
    }

    private func markForeign(_ key: String) {
        var entry = cache[key] ?? AccountUsage()
        entry.windows = []
        entry.fetchedAt = nil
        entry.note = Self.foreignNote
        cache[key] = entry
        persist()
    }

    /// Renews a saved login, once at a time per account, and stores the result before returning.
    public func renew(_ account: StoredAccount, vault: AccountVault) async -> Renewal {
        if let running = renewing[account.id] { return await running.value }
        let saved = unsaved[account.id] ?? vault.credentials(for: account)
        let task = Task<Renewal, Never> {
            guard let saved, ClaudeCredential.isLogin(saved), !ClaudeCredential.isLoginExpired(saved) else { return .dead }
            // Checked right before spending the token: the account may have become the one in use meanwhile.
            if ClaudeCredential.sameGeneration(saved, vault.liveCredentials()) { return .inUse }
            switch await ClaudeOAuth.refresh(credentials: saved) {
            case .success(let renewed):
                for attempt in 0..<3 {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                    if (try? vault.commitRefresh(renewed, for: account.id, spent: saved)) != nil { return .renewed(renewed) }
                }
                return .renewed(renewed)
            case .failure(.unauthorized):
                // Another holder may have renewed it a moment ago (that spends the token we held): look again.
                if let again = vault.credentials(for: account), again != saved, ClaudeCredential.isLogin(again) {
                    return ClaudeCredential.isExpired(again) ? .unavailable : .renewed(again)
                }
                return .dead
            case .failure: return .unavailable
            }
        }
        renewing[account.id] = task
        let result = await task.value
        renewing[account.id] = nil
        if case .renewed(let renewed) = result { unsaved[account.id] = renewed == vault.credentials(for: account) ? nil : renewed }
        if result == .dead {
            var entry = cache[account.id] ?? AccountUsage()
            entry.note = Self.deadNote
            cache[account.id] = entry
            persist()
        }
        return result
    }

    /// Before an account is put in use: its token must outlive Claude Code's own five-minute renewal margin,
    /// so a session that is running reads the new login instead of renewing the previous one over it.
    public func freshen(_ account: StoredAccount, vault: AccountVault, now: Date = Date()) async -> Renewal {
        guard let saved = unsaved[account.id] ?? vault.credentials(for: account), ClaudeCredential.isLogin(saved) else { return .dead }
        if ClaudeCredential.sameGeneration(saved, vault.liveCredentials()) { return .inUse }
        guard ClaudeCredential.isExpired(saved, now: now, margin: 600) else { return .renewed(saved) }
        return await renew(account, vault: vault)
    }

    /// Whether an account's reading should be asked again now.
    static func isDue(last: Date?, entry: AccountUsage?, active: Bool, busy: Bool, urgent: Bool = false, backoff: TimeInterval?,
                      recentlyLimited: Bool = false, force: Bool = false, interval: TimeInterval, activeInterval: TimeInterval,
                      urgentInterval: TimeInterval = 90, now: Date) -> Bool {
        guard let last else { return true }
        let waited = now.timeIntervalSince(last)
        if let backoff { return waited >= backoff }
        // "Actualizar" asks at once, but never twice within a minute.
        if force { return waited >= 60 }
        var wait = active && busy ? (urgent ? urgentInterval : activeInterval) : interval
        // A window that has reset since the reading: the figure on screen is no longer true.
        if entry?.windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) ?? false { wait = min(wait, 60) }
        if recentlyLimited { wait = max(wait, 360) }
        return waited >= wait
    }

    /// The wait after a "too many requests" answer: what the server asked plus a margin, at least five minutes,
    /// doubling while it keeps refusing.
    static func backoffAfterLimit(previous: TimeInterval?, retryAfter: TimeInterval?, maximum: TimeInterval) -> TimeInterval {
        let doubled = previous.map { $0 * 2 } ?? 300
        return min(max(doubled, (retryAfter ?? 0) + 60, 300), maximum)
    }

    /// Reads one account's usage into `entry` and keeps the pace bookkeeping.
    private func read(_ key: String, token: String, into entry: inout AccountUsage, activeNote: Bool, now: Date) async {
        let (result, retryAfter) = await ClaudeOAuth.usageReading(accessToken: token)
        switch result {
        case .success(let windows):
            let peak = { (list: [AccountUsage.Window]) in list.filter { ["5 h", "7 días"].contains($0.name) }.map(\.percent).max() ?? 0 }
            rising[key] = !entry.windows.isEmpty && peak(windows) > peak(entry.windows)
            entry.windows = windows
            entry.fetchedAt = now
            entry.note = nil
            backoff[key] = nil
        case .failure(.unauthorized): entry.note = activeNote ? "se actualizará cuando uses Claude Code" : Self.deadNote
        case .failure(.rateLimited):
            entry.note = "límite de consultas; se reintenta luego"
            backoff[key] = Self.backoffAfterLimit(previous: backoff[key], retryAfter: retryAfter, maximum: maxBackoff)
            limitedAt[key] = now
        case .failure(.network): entry.note = "sin conexión"
        }
    }

    private func due(_ key: String, active: Bool, busy: Bool, force: Bool, switchAt: Double?, now: Date) -> Bool {
        let entry = cache[key]
        let peak = entry?.windows.filter { ["5 h", "7 días"].contains($0.name) }.map(\.percent).max() ?? 0
        let urgent = active && rising[key] == true && switchAt.map { peak >= $0 - 10 } == true
        let recentlyLimited = limitedAt[key].map { now.timeIntervalSince($0) < 3600 } ?? false
        return Self.isDue(last: lastAttempt[key], entry: entry, active: active, busy: busy, urgent: urgent, backoff: backoff[key],
                          recentlyLimited: recentlyLimited, force: force, interval: interval, activeInterval: activeInterval,
                          urgentInterval: urgentInterval, now: now)
    }

    /// Where the status line relay leaves the limits Claude Code itself knows (see `ClaudeStatusLine`).
    private let relayDirectory: URL?

    /// The relay's figures that belong to the account `key`, while they are recent enough to stand for it.
    private func relay(for key: String, email: String, keys: [String], now: Date) -> ClaudeStatusLine.Limits? {
        guard let relayDirectory else { return nil }
        let readings = ClaudeStatusLine.readAll(directory: relayDirectory)
        guard !readings.isEmpty else { return nil }
        let week = { (k: String) in self.cache[k]?.windows.first { $0.name == "7 días" }?.resetsAt }
        let others = keys.filter { $0 != key }.compactMap(week).filter { $0 > now }
        return ClaudeStatusLine.attribute(readings, email: email, known: week(key), others: others, now: now)
    }

    static func applying(_ limits: ClaudeStatusLine.Limits, to entry: inout AccountUsage) {
        let names = Set(limits.windows.map(\.name))
        entry.windows = limits.windows + entry.windows.filter { !names.contains($0.name) }
        entry.fetchedAt = limits.at
        entry.note = nil
    }

    /// With the relay's figures, the endpoint is asked only now and then, for the per-model windows it alone has.
    static let relayEndpointInterval: TimeInterval = 900

    public init(directory: URL?) {
        relayDirectory = directory
        url = directory?.appendingPathComponent("account-usage.json")
        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            cache = (try? decoder.decode([String: AccountUsage].self, from: data)) ?? [:]
        }
    }

    public func snapshot() -> [String: AccountUsage] { cache }

    private func persist() {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(cache) { try? data.write(to: url, options: .atomic) }
    }

    /// Updates the readings that are due. `force`: the user pressed "Actualizar" (still at most once a minute,
    /// and never against a "too many requests"). `busy`: the agent spent tokens since the last call.
    /// `switchAt`: the automatic switch line, near which the account in use is read sooner.
    public func refresh(vault: AccountVault, force: Bool = false, busy: Bool = false, switchAt: Double? = nil, now: Date = Date()) async -> [String: AccountUsage] {
        let accounts = vault.accounts().filter { $0.agent == AccountVault.claude }
        // A login that was never saved as an account is read too, under its own key: someone with a single
        // Claude Code login sees their limits without saving anything first.
        let unsavedLive = vault.activeAccount() == nil ? vault.liveIdentity().map { Self.liveKey($0.email) } : nil
        cache = cache.filter { entry in entry.key == unsavedLive || accounts.contains { $0.id == entry.key } }
        for (id, renewed) in unsaved where (try? vault.commitRefresh(renewed, for: id)) != nil { unsaved[id] = nil }
        let identityKnown = vault.liveIdentity() != nil
        let keys = accounts.map(\.id) + (unsavedLive.map { [$0] } ?? [])
        for account in accounts {
            // Asked again for every account: the user may switch while the previous one was on the network.
            let live = vault.liveCredentials()
            var credentials = unsaved[account.id] ?? vault.credentials(for: account)
            // In use when Claude Code says so, or when it holds this same login generation (its config may be
            // in the middle of a write and unreadable for a moment).
            let isActive = account.id == vault.activeAccount()?.id || ClaudeCredential.sameGeneration(credentials, live)
            // The login in use belongs to Claude Code: read it, never renew it from here.
            if isActive { credentials = live }
            // Already known to hold another account's login: nothing it shows would be its own.
            if case .foreign = knownOwnership(of: account.id, uuid: account.accountUuid, email: account.email, credentials: credentials) {
                markForeign(account.id)
                continue
            }
            // Claude Code's own figures, handed to its status line: no request, never "too many requests". They are
            // matched to an account by its week, so a session still open on the previous account feeds that account.
            let relayed = relay(for: account.id, email: account.email, keys: keys, now: now)
            if let relayed {
                var entry = cache[account.id] ?? AccountUsage()
                Self.applying(relayed, to: &entry)
                cache[account.id] = entry
                let recent = lastAttempt[account.id].map { now.timeIntervalSince($0) < Self.relayEndpointInterval } ?? false
                if recent || backoff[account.id].map({ now.timeIntervalSince(lastAttempt[account.id] ?? .distantPast) < $0 }) == true { continue }
            } else if !due(account.id, active: isActive, busy: busy, force: force, switchAt: switchAt, now: now) { continue }
            lastAttempt[account.id] = now
            var entry = cache[account.id] ?? AccountUsage()
            if !isActive, let saved = credentials, ClaudeCredential.isLoginExpired(saved, now: now) {
                // The login itself lapsed: only a new sign-in brings it back, so no renewal is spent on it.
                entry.note = Self.deadNote
                cache[account.id] = entry
                continue
            }
            if !isActive, let saved = credentials, ClaudeCredential.isExpired(saved) {
                // Without knowing who is logged in, a renewal could spend the login Claude Code is using.
                guard identityKnown || live == nil else { continue }
                switch await renew(account, vault: vault) {
                case .renewed(let renewed): credentials = renewed
                case .inUse: credentials = vault.liveCredentials()
                case .dead: continue
                case .unavailable:
                    entry.note = "sin conexión"
                    cache[account.id] = entry
                    continue
                }
            }
            guard let token = ClaudeCredential.accessToken(credentials) else {
                entry.note = "sin credenciales guardadas"
                cache[account.id] = entry
                continue
            }
            if isActive, ClaudeCredential.isExpired(credentials, margin: 0) {
                entry.note = "se actualizará cuando uses Claude Code"
                cache[account.id] = entry
                continue
            }
            // Whose login this really is, once per renewal: a slot can hold another account's login (a session left
            // open across a switch renews the previous account and writes it back), and its figures would be that one's.
            if case .foreign = await ownership(of: account.id, uuid: account.accountUuid, email: account.email, credentials: credentials) {
                markForeign(account.id)
                continue
            }
            await read(account.id, token: token, into: &entry, activeNote: isActive, now: now)
            if let relayed { Self.applying(relayed, to: &entry) }
            cache[account.id] = entry
        }
        if let key = unsavedLive, let email = vault.liveIdentity()?.email, let relayed = relay(for: key, email: email, keys: keys, now: now) {
            var entry = cache[key] ?? AccountUsage()
            Self.applying(relayed, to: &entry)
            cache[key] = entry
        } else if let key = unsavedLive, due(key, active: true, busy: busy, force: force, switchAt: switchAt, now: now) {
            lastAttempt[key] = now
            var entry = cache[key] ?? AccountUsage()
            let credentials = vault.liveCredentials()
            if let token = ClaudeCredential.accessToken(credentials), !ClaudeCredential.isExpired(credentials, margin: 0) {
                await read(key, token: token, into: &entry, activeNote: true, now: now)
            } else {
                entry.note = credentials == nil ? nil : "se actualizará cuando uses Claude Code"
            }
            cache[key] = entry
        }
        persist()
        return cache
    }

    /// Key of the reading that belongs to a login in use that is not a saved account.
    public static func liveKey(_ email: String) -> String { "live|" + email.lowercased() }
}
