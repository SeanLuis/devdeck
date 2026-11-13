import Foundation

/// Codex logins in the same store. Codex keeps its login in one file, `~/.codex/auth.json`
/// (ChatGPT tokens or an API key); switching account means swapping that file for a saved copy.
extension AccountVault {
    public static let codex = "Codex"

    var codexAuthPath: String { home + "/.codex/auth.json" }

    public struct CodexIdentity: Hashable, Sendable {
        public let email: String
        /// ChatGPT account (workspace) id; tells apart two workspaces of the same person.
        public let accountID: String?
        public let plan: String?
    }

    /// Who a Codex auth file belongs to. Only the unsigned claims of its id token are read.
    public static func codexIdentity(auth: String?) -> CodexIdentity? {
        guard let auth, let root = try? JSONSerialization.jsonObject(with: Data(auth.utf8)) as? [String: Any] else { return nil }
        if let tokens = root["tokens"] as? [String: Any], let id = tokens["id_token"] as? String, let claims = AgentAccounts.jwtClaims(id),
           let email = claims["email"] as? String {
            let plan = (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
            return CodexIdentity(email: email, accountID: tokens["account_id"] as? String, plan: plan)
        }
        if (root["OPENAI_API_KEY"] as? String)?.isEmpty == false { return CodexIdentity(email: "API key", accountID: nil, plan: nil) }
        return nil
    }

    public func liveCodexAuth() -> String? { try? String(contentsOfFile: codexAuthPath, encoding: .utf8) }

    public func liveCodexIdentity() -> CodexIdentity? { Self.codexIdentity(auth: liveCodexAuth()) }

    public func activeCodexAccount() -> StoredAccount? {
        guard let live = liveCodexIdentity() else { return nil }
        return accounts().first { $0.agent == Self.codex && $0.matches(email: live.email, organization: live.accountID) }
    }

    /// Saves the login Codex is using now (or refreshes its saved copy: Codex renews its tokens in that file).
    @discardableResult
    public func addCurrentCodex() throws -> StoredAccount {
        lock.lock(); defer { lock.unlock() }
        guard let auth = liveCodexAuth(), let live = Self.codexIdentity(auth: auth) else { throw AccountVaultError.notLoggedIn }
        var list = accounts()
        let account: StoredAccount
        if let existing = list.first(where: { $0.agent == Self.codex && $0.matches(email: live.email, organization: live.accountID) }) {
            account = existing
        } else {
            account = StoredAccount(agent: Self.codex, email: live.email, organizationUuid: live.accountID, organizationName: live.plan)
            list.append(account)
        }
        try keychain.set(service: Self.service, account: slot(account), secret: auth)
        save(list)
        return account
    }

    /// Makes `id` the account Codex uses. The login in use is saved first, so nothing is lost.
    public func switchCodex(to id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let target = accounts().first(where: { $0.id == id && $0.agent == Self.codex }) else { throw AccountVaultError.unknownAccount }
        guard let saved = try keychain.get(service: Self.service, account: slot(target)), Self.codexIdentity(auth: saved) != nil else {
            throw AccountVaultError.missingCredentials(target.email)
        }
        let original = liveCodexAuth()
        if let live = Self.codexIdentity(auth: original) {
            if target.matches(email: live.email, organization: live.accountID) { return }
            try addCurrentCodex()
        }
        let url = URL(fileURLWithPath: codexAuthPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(saved.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        guard let now = liveCodexIdentity(), target.matches(email: now.email, organization: now.accountID) else {
            if let original { try? Data(original.utf8).write(to: url, options: .atomic) }
            throw AccountVaultError.writeNotVerified
        }
    }
}
