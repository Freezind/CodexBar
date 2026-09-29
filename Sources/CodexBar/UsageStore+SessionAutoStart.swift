import CodexBarCore
import Foundation

extension UsageStore {
    /// Opens an idle 5-hour session for providers whose opt-in auto-start is enabled, then refreshes the
    /// provider shortly after so the menu shows the newly running window.
    func evaluateSessionAutoStart(provider: UsageProvider, snapshot: UsageSnapshot, isTokenAccountScoped: Bool) {
        // The CLI prompt always runs as the provider's signed-in default account; never attribute it to a token
        // account row.
        guard !isTokenAccountScoped, self.settings.sessionAutoStartEnabled(for: provider) else { return }
        self.sessionAutoStarter.evaluate(
            provider: provider,
            snapshot: snapshot,
            environment: {
                ProviderRegistry.makeEnvironment(
                    base: self.environmentBase,
                    provider: provider,
                    settings: self.settings,
                    tokenOverride: nil)
            },
            onStarted: { [weak self] in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: SessionAutoStarter.followUpRefreshDelay)
                    await self?.refreshProvider(provider, coalesceIfRefreshing: true)
                }
            })
    }
}
