import CodexBarCore
import Foundation

/// Decides whether an opt-in 5-hour session auto-start should fire for a freshly published snapshot.
///
/// Pure by construction: callers pass the snapshot, the last attempt time, and the clock. The policy only
/// fires when the session lane positively reads as "clock not running"; missing or ambiguous data skips.
enum SessionAutoStartPolicy {
    static let sessionWindowMinutes = 5 * 60
    /// Never attempt more than once per this interval per provider, whether the attempt succeeded or not.
    static let minimumAttemptInterval: TimeInterval = 30 * 60
    /// An idle Codex lane reports a reset one full window after the fetch; allow for clock skew and latency.
    static let fullWindowTolerance: TimeInterval = 90

    enum Decision: Equatable {
        case start
        case skip(SkipReason)
    }

    enum SkipReason: String, Equatable {
        case noSessionWindow
        case notSessionLane
        case sessionRunning
        case recentlyAttempted
    }

    static func decide(snapshot: UsageSnapshot, lastAttemptAt: Date?, now: Date) -> Decision {
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < self.minimumAttemptInterval {
            return .skip(.recentlyAttempted)
        }
        guard let window = snapshot.primary else { return .skip(.noSessionWindow) }
        if let minutes = window.windowMinutes, minutes != self.sessionWindowMinutes {
            return .skip(.notSessionLane)
        }
        return self.isSessionIdle(window, measuredAt: snapshot.updatedAt) ? .start : .skip(.sessionRunning)
    }

    /// Whether the 5-hour clock is not running at measurement time. Keyed off the reset clock rather than raw
    /// usage: a session that just started sits at 0% but is running.
    static func isSessionIdle(_ window: RateWindow, measuredAt: Date) -> Bool {
        // Claude reports no five-hour lane at all while no session is open.
        if window.isSyntheticPlaceholder { return true }
        guard let resetsAt = window.resetsAt else {
            // Providers that omit a reset while idle still report unused quota.
            return window.usedPercent <= 0
        }
        let remaining = resetsAt.timeIntervalSince(measuredAt)
        if remaining <= 0 { return true }
        // Codex keeps projecting a full window ahead until the first request starts the clock.
        let windowSeconds = TimeInterval((window.windowMinutes ?? self.sessionWindowMinutes) * 60)
        return window.usedPercent <= 0 && remaining >= windowSeconds - self.fullWindowTolerance
    }
}
