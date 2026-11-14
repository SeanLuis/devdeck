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

    private static func send(_ request: URLRequest) async -> Result<Data, Failure> {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200..<300: return .success(data)
            case 400, 401, 403: return .failure(.unauthorized)
            case 429: return .failure(.rateLimited)
            default: return .failure(.network)
            }
        } catch {
            return .failure(.network)
        }
    }

    public static func usage(accessToken: String) async -> Result<[AccountUsage.Window], Failure> {
        var request = URLRequest(url: usageURL, timeoutInterval: 12)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return await send(request).map(parseUsage)
    }

    /// Renews the access token of a saved login. Returns the whole credential, ready to store.
    public static func refresh(credentials: String) async -> Result<String, Failure> {
        guard let refreshToken = ClaudeCredential.oauth(credentials)?["refreshToken"] as? String, !refreshToken.isEmpty else { return .failure(.unauthorized) }
        var request = URLRequest(url: tokenURL, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
        switch await send(request) {
        case .failure(let failure): return .failure(failure)
        case .success(let data):
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let updated = ClaudeCredential.applyingRefresh(credentials, response: response) else { return .failure(.network) }
            return .success(updated)
        }
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
    /// Seconds between two readings of the same account.
    public var interval: TimeInterval = 300
    /// The account in use moves while the agent works: read it this often when tokens were just spent.
    public var activeInterval: TimeInterval = 90
    /// Longest wait after the account keeps answering "too many requests".
    public var maxBackoff: TimeInterval = 1800
    /// Extra wait per account after a "too many requests" answer; doubles each time, cleared by a good read.
    private var backoff: [String: TimeInterval] = [:]

    /// Whether an account's reading should be asked again now.
    static func isDue(last: Date?, entry: AccountUsage?, active: Bool, busy: Bool, backoff: TimeInterval?,
                      interval: TimeInterval, activeInterval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        let waited = now.timeIntervalSince(last)
        if let backoff { return waited >= backoff }
        // A window that has reset since the reading: the figure on screen is no longer true.
        let expired = entry?.windows.contains { ($0.resetsAt ?? .distantFuture) <= now } ?? false
        if expired, waited >= min(60, activeInterval) { return true }
        return waited >= (active && busy ? activeInterval : interval)
    }

    public init(directory: URL?) {
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

    /// Updates the readings that are due. `force` ignores the interval (the user pressed "Actualizar").
    /// `busy`: the agent spent tokens since the last call, so the account in use is read at the short interval.
    public func refresh(vault: AccountVault, force: Bool = false, busy: Bool = false, now: Date = Date()) async -> [String: AccountUsage] {
        let accounts = vault.accounts().filter { $0.agent == AccountVault.claude }
        // A login that was never saved as an account is read too, under its own key: someone with a single
        // Claude Code login sees their limits without saving anything first.
        let unsavedLive = vault.activeAccount() == nil ? vault.liveIdentity().map { Self.liveKey($0.email) } : nil
        cache = cache.filter { entry in entry.key == unsavedLive || accounts.contains { $0.id == entry.key } }
        for (id, renewed) in unsaved where (try? vault.commitRefresh(renewed, for: id)) != nil { unsaved[id] = nil }
        for account in accounts {
            // Asked again for every account: the user may switch while the previous one was on the network.
            let isActive = account.id == vault.activeAccount()?.id
            if !force, !Self.isDue(last: lastAttempt[account.id], entry: cache[account.id], active: isActive, busy: busy,
                                   backoff: backoff[account.id], interval: interval, activeInterval: activeInterval, now: now) { continue }
            lastAttempt[account.id] = now
            var entry = cache[account.id] ?? AccountUsage()
            // The login in use belongs to Claude Code: read it, never renew it from here.
            var credentials = isActive ? vault.liveCredentials() : (unsaved[account.id] ?? vault.credentials(for: account))
            if !isActive, let saved = credentials, ClaudeCredential.isExpired(saved) {
                switch await ClaudeOAuth.refresh(credentials: saved) {
                case .success(let renewed):
                    var stored = false
                    for attempt in 0..<3 where !stored {
                        if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                        stored = (try? vault.commitRefresh(renewed, for: account.id)) != nil
                    }
                    if !stored { unsaved[account.id] = renewed }
                    credentials = renewed
                case .failure(.unauthorized):
                    // Another tool may have renewed this login a moment ago (that spends the refresh token we held):
                    // look again before calling the login dead.
                    if let again = vault.credentials(for: account), again != saved, !ClaudeCredential.isExpired(again) {
                        credentials = again
                    } else {
                        entry.note = "sesión caducada: vuelve a iniciar sesión"
                        cache[account.id] = entry
                        continue
                    }
                case .failure:
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
            switch await ClaudeOAuth.usage(accessToken: token) {
            case .success(let windows):
                entry.windows = windows
                entry.fetchedAt = now
                entry.note = nil
                backoff[account.id] = nil
            case .failure(.unauthorized): entry.note = isActive ? "se actualizará cuando uses Claude Code" : "sesión caducada: vuelve a iniciar sesión"
            case .failure(.rateLimited):
                entry.note = "límite de consultas; se reintenta luego"
                backoff[account.id] = min((backoff[account.id] ?? interval) * 2, maxBackoff)
            case .failure(.network): entry.note = "sin conexión"
            }
            cache[account.id] = entry
        }
        if let key = unsavedLive, force || Self.isDue(last: lastAttempt[key], entry: cache[key], active: true, busy: busy, backoff: backoff[key],
                                                    interval: interval, activeInterval: activeInterval, now: now) {
            lastAttempt[key] = now
            var entry = cache[key] ?? AccountUsage()
            let credentials = vault.liveCredentials()
            if let token = ClaudeCredential.accessToken(credentials), !ClaudeCredential.isExpired(credentials, margin: 0) {
                switch await ClaudeOAuth.usage(accessToken: token) {
                case .success(let windows):
                    entry.windows = windows
                    entry.fetchedAt = now
                    entry.note = nil
                    backoff[key] = nil
                case .failure(.unauthorized): entry.note = "se actualizará cuando uses Claude Code"
                case .failure(.rateLimited):
                    entry.note = "límite de consultas; se reintenta luego"
                    backoff[key] = min((backoff[key] ?? interval) * 2, maxBackoff)
                case .failure(.network): entry.note = "sin conexión"
                }
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
