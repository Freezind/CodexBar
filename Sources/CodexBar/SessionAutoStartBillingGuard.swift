import CodexBarCore
import Foundation

/// Keeps the auto-start ping on the user's subscription, where it only spends the 5-hour window the plan already
/// includes. A CLI that would authenticate with an API key or a third-party provider is billed per request, so the
/// ping is refused instead of silently creating charges.
enum SessionAutoStartBillingGuard {
    enum Failure: LocalizedError, Equatable {
        case notSubscriptionAuth
        case accountMismatch

        var errorDescription: String? {
            switch self {
            case .notSubscriptionAuth:
                "The CLI is not signed in with a subscription; skipping to avoid per-request API billing."
            case .accountMismatch:
                "The CLI is signed in to a different account than the idle session; skipping."
            }
        }
    }

    /// The ping runs as the CLI's signed-in account, while the idle decision came from CodexBar's snapshot. They can
    /// diverge (a stale credentials file, a CLI login switch, an account-switching tool), and a ping would then open
    /// another account's window. A snapshot without an email came from the CLI itself (Claude `/usage`), so it has
    /// nothing to diverge from; otherwise the CLI must report the same email.
    static func accountMatches(snapshotEmail: String?, cliEmail: String?) -> Bool {
        guard let expected = self.normalizedEmail(snapshotEmail) else { return true }
        return self.normalizedEmail(cliEmail) == expected
    }

    /// Email of the ChatGPT sign-in in `auth.json`, read from its unverified `id_token` claims.
    static func codexAccountEmail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let payload = UsageFetcher.parseJWT(idToken)
        else { return nil }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return self.normalizedEmail((payload["email"] as? String) ?? (profile?["email"] as? String))
    }

    /// Email reported by `claude auth status --json`.
    static func claudeAccountEmail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return self.normalizedEmail(json["email"] as? String)
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Provider-specific by design: each CLI reads its own variables that route it to API-key auth, a custom
    /// endpoint, or a cloud provider.
    static let strippedEnvironmentKeys: [UsageProvider: [String]] = [
        .codex: ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"],
        .claude: [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
        ],
    ]

    static func sanitizedEnvironment(_ environment: [String: String], for provider: UsageProvider) -> [String: String] {
        var env = environment
        for key in self.strippedEnvironmentKeys[provider] ?? [] {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// `$CODEX_HOME/auth.json` must hold a ChatGPT sign-in and no stored API key.
    static func isCodexSubscriptionAuth(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return false
        }
        if let mode = json["auth_mode"] as? String {
            return mode.lowercased() == "chatgpt"
        }
        // Older auth files predate `auth_mode`; a token bundle without an API key is a ChatGPT sign-in.
        return json["tokens"] is [String: Any]
    }

    /// `claude auth status --json` must report a claude.ai sign-in against Anthropic's first-party API.
    static func isClaudeSubscriptionAuth(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["loggedIn"] as? Bool == true
            && (json["authMethod"] as? String)?.lowercased() == "claude.ai"
            && (json["apiProvider"] as? String)?.lowercased() == "firstparty"
    }

    static func codexAuthFileURL(environment: [String: String], fileManager: FileManager = .default) -> URL {
        let hasScopedHome = !(environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            .isEmpty
        // Provider-specific by design: Codex keeps its sign-in in its own home directory.
        let home = hasScopedHome
            ? CodexHomeScope.ambientHomeURL(env: environment, fileManager: fileManager)
            : fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }
}
