import CodexBarCore
import Foundation

/// Opt-in automation that opens an idle 5-hour session window by sending one minimal prompt through the
/// provider's own CLI, so the window starts counting without the user opening an agent first.
///
/// The prompt spends a negligible amount of quota by design; that request is what starts the clock. It always runs
/// as the CLI's signed-in account, so a token account is eligible only when it is bound to that account by email.
@MainActor
final class SessionAutoStarter {
    /// `expectedAccountEmail` is the idle snapshot's account; the runner refuses to ping a different CLI account.
    typealias CommandRunner = @Sendable (
        _ provider: UsageProvider,
        _ environment: [String: String],
        _ expectedAccountEmail: String?) async throws -> Void

    nonisolated static let prompt = "ping"
    /// Time between a successful start and the follow-up refresh that publishes the running window.
    static let followUpRefreshDelay: Duration = .seconds(20)
    private nonisolated static let commandTimeout: TimeInterval = 120

    /// Surfaces a skipped start the user has to fix; posted once per episode, not on every retry.
    typealias AccountMismatchNotifier = @MainActor (_ provider: UsageProvider) -> Void

    private let runCommand: CommandRunner
    private let notifyAccountMismatch: AccountMismatchNotifier
    private let logger = CodexBarLog.logger(LogCategories.sessionAutoStart)
    private var lastAttemptAt: [UsageProvider: Date] = [:]
    private var inFlight: Set<UsageProvider> = []
    private var accountMismatchNotified: Set<UsageProvider> = []

    init(
        runCommand: @escaping CommandRunner = SessionAutoStarter.runCLI,
        notifyAccountMismatch: @escaping AccountMismatchNotifier = SessionAutoStarter.postAccountMismatchNotification)
    {
        self.runCommand = runCommand
        self.notifyAccountMismatch = notifyAccountMismatch
    }

    nonisolated static func supports(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: only the Codex and Claude CLIs can open a 5-hour window with one prompt.
        provider == .codex || provider == .claude
    }

    /// Starts the session when the policy says the published snapshot is idle. Returns the in-flight task so
    /// tests can await it; `onStarted` runs on the main actor after a successful start.
    @discardableResult
    func evaluate(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        environment: () -> [String: String],
        now: Date = Date(),
        onStarted: @escaping @MainActor () -> Void) -> Task<Void, Never>?
    {
        guard Self.supports(provider), !self.inFlight.contains(provider) else { return nil }
        let decision = SessionAutoStartPolicy.decide(
            snapshot: snapshot,
            lastAttemptAt: self.lastAttemptAt[provider],
            now: now,
            longerPrimaryMeansIdleSession: Self.longerPrimaryMeansIdleSession(provider))
        guard decision == .start else { return nil }

        self.lastAttemptAt[provider] = now
        self.inFlight.insert(provider)
        let env = environment()
        let expectedAccountEmail = snapshot.accountEmail(for: provider)
        let runCommand = self.runCommand
        self.logger.info("Starting idle session", metadata: ["provider": provider.rawValue])
        return Task { @MainActor [weak self] in
            do {
                try await runCommand(provider, env, expectedAccountEmail)
                self?.logger.info("Session started", metadata: ["provider": provider.rawValue])
                self?.inFlight.remove(provider)
                self?.accountMismatchNotified.remove(provider)
                onStarted()
            } catch {
                self?.logger.warning(
                    "Session auto-start failed",
                    metadata: ["provider": provider.rawValue, "error": Self.logSafeDescription(error)])
                self?.inFlight.remove(provider)
                if error as? SessionAutoStartBillingGuard.Failure == .accountMismatch {
                    self?.noteAccountMismatch(provider)
                }
            }
        }
    }

    private func noteAccountMismatch(_ provider: UsageProvider) {
        guard self.accountMismatchNotified.insert(provider).inserted else { return }
        self.notifyAccountMismatch(provider)
    }

    static func postAccountMismatchNotification(_ provider: UsageProvider) {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        // A stable identifier replaces an older alert instead of stacking; emails stay out of the text.
        AppNotifications.shared.post(
            idPrefix: "session-auto-start-account-\(provider.rawValue)",
            title: "\(name) 5h session not auto-started",
            body: "The \(name) CLI is signed in to a different account than the one CodexBar shows. "
                + "Sign the CLI in to the same account, or refresh CodexBar, to resume auto-start.",
            soundEnabled: false,
            identifier: "codexbar-session-auto-start-account-\(provider.rawValue)")
    }

    /// Claude's OAuth usage omits `five_hour` while no session is open, so the weekly lane is promoted to primary.
    /// Codex plans without a session lane also report a weekly primary, so Codex must not treat it as idle.
    nonisolated static func longerPrimaryMeansIdleSession(_ provider: UsageProvider) -> Bool {
        // Provider-specific by design: only Claude promotes its weekly lane when the session lane is absent.
        provider == .claude
    }

    /// CLI stderr can echo account details, so failures log only the error category.
    nonisolated static func logSafeDescription(_ error: Error) -> String {
        switch error as? SessionAutoStartBillingGuard.Failure {
        case .notSubscriptionAuth: return "not-subscription-auth"
        case .accountMismatch: return "account-mismatch"
        case nil: break
        }
        return switch error as? SubprocessRunnerError {
        case .binaryNotFound: "binary-not-found"
        case .launchFailed: "launch-failed"
        case .timedOut: "timed-out"
        case .outputTooLarge: "output-too-large"
        case let .nonZeroExit(code, _): "exit-\(code)"
        case nil: String(describing: type(of: error))
        }
    }

    // MARK: - CLI

    nonisolated static func arguments(for provider: UsageProvider, workingDirectory: String) -> [String] {
        // Provider-specific by design: each CLI needs its own minimal non-interactive prompt flags.
        switch provider {
        case .claude:
            // No tools, MCP servers, skills, or saved transcript: one cheap turn on the smallest model.
            [
                "-p", self.prompt,
                "--model", "haiku",
                "--tools", "",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--output-format", "json",
            ]
        default:
            // `config.toml` can route to another provider with its own credentials, so it is skipped and the
            // built-in OpenAI provider is pinned to the ChatGPT sign-in.
            [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--json",
                "--sandbox", "read-only",
                "-c", "model_provider=\"openai\"",
                "-c", "forced_login_method=\"chatgpt\"",
                "-c", "model_reasoning_effort=\"low\"",
                "-C", workingDirectory,
                self.prompt,
            ]
        }
    }

    nonisolated static func runCLI(
        provider: UsageProvider,
        environment: [String: String],
        expectedAccountEmail: String?) async throws
    {
        var env = SessionAutoStartBillingGuard.sanitizedEnvironment(environment, for: provider)
        let loginPATH = LoginShellPathCache.shared.current
        env["PATH"] = PathBuilder.effectivePATH(
            purposes: [.rpc, .tty, .nodeTooling],
            env: env,
            loginPATH: loginPATH)
        // Provider-specific by design: the prompt must run through the provider's own signed-in CLI.
        let binary = provider == .claude
            ? BinaryLocator.resolveClaudeBinary(env: env, loginPATH: loginPATH)
            : BinaryLocator.resolveCodexBinary(env: env, loginPATH: loginPATH)
        guard let binary else {
            throw SubprocessRunnerError.binaryNotFound(provider == .claude ? "claude" : "codex")
        }
        // An empty scratch directory keeps project instructions, hooks, and repo state out of the prompt.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-session-auto-start", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        // Checked immediately before launch so the ping runs as the account whose idle window was observed.
        try await Self.requireSubscriptionAuth(
            provider: provider,
            binary: binary,
            environment: env,
            workingDirectory: workingDirectory,
            expectedAccountEmail: expectedAccountEmail)
        _ = try await SubprocessRunner.run(
            binary: binary,
            arguments: Self.arguments(for: provider, workingDirectory: workingDirectory.path),
            environment: env,
            timeout: Self.commandTimeout,
            standardInput: FileHandle.nullDevice,
            currentDirectoryURL: workingDirectory,
            reapDescendants: true,
            label: "\(provider.rawValue)-session-auto-start")
    }

    private nonisolated static func requireSubscriptionAuth(
        provider: UsageProvider,
        binary: String,
        environment: [String: String],
        workingDirectory: URL,
        expectedAccountEmail: String?) async throws
    {
        // Provider-specific by design: each CLI exposes its sign-in method differently.
        let isSubscription: Bool
        let cliAccountEmail: String?
        if provider == .claude {
            let status = try await SubprocessRunner.run(
                binary: binary,
                arguments: ["auth", "status", "--json"],
                environment: environment,
                timeout: 20,
                standardInput: FileHandle.nullDevice,
                currentDirectoryURL: workingDirectory,
                acceptsNonZeroExit: true,
                label: "claude-session-auto-start-auth")
            let data = Data(status.stdout.utf8)
            isSubscription = SessionAutoStartBillingGuard.isClaudeSubscriptionAuth(data)
            cliAccountEmail = SessionAutoStartBillingGuard.claudeAccountEmail(data)
        } else {
            let url = SessionAutoStartBillingGuard.codexAuthFileURL(environment: environment)
            let data = try? Data(contentsOf: url)
            isSubscription = data.map(SessionAutoStartBillingGuard.isCodexSubscriptionAuth) ?? false
            cliAccountEmail = data.flatMap(SessionAutoStartBillingGuard.codexAccountEmail)
        }
        guard isSubscription else { throw SessionAutoStartBillingGuard.Failure.notSubscriptionAuth }
        guard SessionAutoStartBillingGuard.accountMatches(
            snapshotEmail: expectedAccountEmail,
            cliEmail: cliAccountEmail)
        else { throw SessionAutoStartBillingGuard.Failure.accountMismatch }
    }
}
