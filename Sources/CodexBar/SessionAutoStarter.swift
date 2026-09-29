import CodexBarCore
import Foundation

/// Opt-in automation that opens an idle 5-hour session window by sending one minimal prompt through the
/// provider's own CLI, so the window starts counting without the user opening an agent first.
///
/// The prompt spends a negligible amount of quota by design; that request is what starts the clock. It runs
/// only for the provider's default account (the one the CLI is signed in as), never for token accounts.
@MainActor
final class SessionAutoStarter {
    typealias CommandRunner = @Sendable (_ provider: UsageProvider, _ environment: [String: String]) async throws
        -> Void

    nonisolated static let prompt = "ping"
    /// Time between a successful start and the follow-up refresh that publishes the running window.
    static let followUpRefreshDelay: Duration = .seconds(20)
    private nonisolated static let commandTimeout: TimeInterval = 120

    private let runCommand: CommandRunner
    private let logger = CodexBarLog.logger(LogCategories.sessionAutoStart)
    private var lastAttemptAt: [UsageProvider: Date] = [:]
    private var inFlight: Set<UsageProvider> = []

    init(runCommand: @escaping CommandRunner = SessionAutoStarter.runCLI) {
        self.runCommand = runCommand
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
            now: now)
        guard decision == .start else { return nil }

        self.lastAttemptAt[provider] = now
        self.inFlight.insert(provider)
        let env = environment()
        let runCommand = self.runCommand
        self.logger.info("Starting idle session", metadata: ["provider": provider.rawValue])
        return Task { @MainActor [weak self] in
            do {
                try await runCommand(provider, env)
                self?.logger.info("Session started", metadata: ["provider": provider.rawValue])
                self?.inFlight.remove(provider)
                onStarted()
            } catch {
                self?.logger.warning(
                    "Session auto-start failed",
                    metadata: ["provider": provider.rawValue, "error": Self.logSafeDescription(error)])
                self?.inFlight.remove(provider)
            }
        }
    }

    /// CLI stderr can echo account details, so failures log only the error category.
    nonisolated static func logSafeDescription(_ error: Error) -> String {
        switch error as? SubprocessRunnerError {
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
            [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--json",
                "--sandbox", "read-only",
                "-c", "model_reasoning_effort=\"low\"",
                "-C", workingDirectory,
                self.prompt,
            ]
        }
    }

    nonisolated static func runCLI(provider: UsageProvider, environment: [String: String]) async throws {
        var env = environment
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
}
