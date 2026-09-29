import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SessionAutoStartPolicyTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func snapshot(
        usedPercent: Double = 0,
        windowMinutes: Int? = 300,
        resetsIn: TimeInterval?,
        isSyntheticPlaceholder: Bool = false,
        includePrimary: Bool = true) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: includePrimary
                ? RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: windowMinutes,
                    resetsAt: resetsIn.map { Self.now.addingTimeInterval($0) },
                    resetDescription: nil,
                    isSyntheticPlaceholder: isSyntheticPlaceholder)
                : nil,
            secondary: nil,
            updatedAt: self.now)
    }

    private static func decide(_ snapshot: UsageSnapshot, lastAttemptAgo: TimeInterval? = nil)
        -> SessionAutoStartPolicy.Decision
    {
        SessionAutoStartPolicy.decide(
            snapshot: snapshot,
            lastAttemptAt: lastAttemptAgo.map { Self.now.addingTimeInterval(-$0) },
            now: self.now)
    }

    @Test
    func `unused window projecting a full reset ahead is idle`() {
        #expect(Self.decide(Self.snapshot(resetsIn: 5 * 3600)) == .start)
        #expect(Self.decide(Self.snapshot(resetsIn: 5 * 3600 - 30)) == .start)
    }

    @Test
    func `freshly started window at zero percent is running`() {
        #expect(Self.decide(Self.snapshot(resetsIn: 5 * 3600 - 10 * 60)) == .skip(.sessionRunning))
    }

    @Test
    func `window with usage is running`() {
        #expect(Self.decide(Self.snapshot(usedPercent: 12, resetsIn: 5 * 3600)) == .skip(.sessionRunning))
        #expect(Self.decide(Self.snapshot(usedPercent: 3, resetsIn: nil)) == .skip(.sessionRunning))
    }

    @Test
    func `elapsed reset is idle`() {
        #expect(Self.decide(Self.snapshot(usedPercent: 80, resetsIn: -60)) == .start)
    }

    @Test
    func `missing reset with no usage is idle`() {
        #expect(Self.decide(Self.snapshot(resetsIn: nil)) == .start)
    }

    @Test
    func `claude placeholder session lane is idle`() {
        #expect(Self.decide(Self.snapshot(resetsIn: nil, isSyntheticPlaceholder: true)) == .start)
    }

    @Test
    func `missing or non session primary lane never starts`() {
        #expect(Self.decide(Self.snapshot(resetsIn: nil, includePrimary: false)) == .skip(.noSessionWindow))
        #expect(Self.decide(Self.snapshot(windowMinutes: 10080, resetsIn: 7 * 86400)) == .skip(.notSessionLane))
    }

    @Test
    func `recent attempt suppresses another start`() {
        let idle = Self.snapshot(resetsIn: nil)
        #expect(Self.decide(idle, lastAttemptAgo: 10 * 60) == .skip(.recentlyAttempted))
        #expect(Self.decide(idle, lastAttemptAgo: 31 * 60) == .start)
    }
}

@MainActor
struct SessionAutoStarterTests {
    private actor Recorder {
        var calls: [UsageProvider] = []
        func record(_ provider: UsageProvider) {
            self.calls.append(provider)
        }
    }

    private struct Failure: Error {}

    private static let idle = UsageSnapshot(
        primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
        secondary: nil,
        updatedAt: Date())

    @Test
    func `idle snapshot runs the command once and reports success`() async {
        let recorder = Recorder()
        let starter = SessionAutoStarter { provider, _ in await recorder.record(provider) }
        var started = 0
        let task = starter.evaluate(
            provider: .codex,
            snapshot: Self.idle,
            environment: { [:] },
            onStarted: { started += 1 })
        await task?.value
        #expect(await recorder.calls == [.codex])
        #expect(started == 1)

        // The cooldown suppresses an immediate repeat even though the snapshot still reads idle.
        #expect(starter.evaluate(provider: .codex, snapshot: Self.idle, environment: { [:] }, onStarted: {}) == nil)
    }

    @Test
    func `failed attempt also honors the cooldown`() async {
        let starter = SessionAutoStarter { _, _ in throw Failure() }
        var started = 0
        await starter.evaluate(
            provider: .claude,
            snapshot: Self.idle,
            environment: { [:] },
            onStarted: { started += 1 })?.value
        #expect(started == 0)
        #expect(starter.evaluate(provider: .claude, snapshot: Self.idle, environment: { [:] }, onStarted: {}) == nil)
    }

    @Test
    func `unsupported providers never run`() {
        let starter = SessionAutoStarter { _, _ in Issue.record("unexpected run") }
        #expect(starter.evaluate(provider: .gemini, snapshot: Self.idle, environment: { [:] }, onStarted: {}) == nil)
    }

    @Test
    func `cli arguments stay minimal and isolated`() {
        let codex = SessionAutoStarter.arguments(for: .codex, workingDirectory: "/tmp/x")
        #expect(codex.first == "exec")
        #expect(codex.contains("--ephemeral"))
        #expect(codex.contains("--skip-git-repo-check"))
        #expect(codex.last == SessionAutoStarter.prompt)

        let claude = SessionAutoStarter.arguments(for: .claude, workingDirectory: "/tmp/x")
        #expect(claude.prefix(2) == ["-p", SessionAutoStarter.prompt])
        #expect(claude.contains("--no-session-persistence"))
        #expect(!claude.contains("--bare"))
    }
}
