import CodexBarCore
import Foundation

extension UsageStore {
    /// Opens an idle 5-hour session for providers whose opt-in auto-start is enabled, then refreshes the
    /// provider shortly after so the menu shows the newly running window.
    ///
    /// - Parameter tokenAccountUsage: the provider's own result for a token-account refresh, before the account
    ///   label is applied; nil for the default account.
    func evaluateSessionAutoStart(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        tokenAccountUsage: UsageSnapshot?)
    {
        guard self.settings.sessionAutoStartEnabled(for: provider) else { return }
        // The CLI prompt always runs as the provider's signed-in default account, so a token account qualifies only
        // when the billing guard can bind it to that CLI account by email.
        if let tokenAccountUsage,
           !SessionAutoStartBillingGuard.tokenAccountCanBind(
               provider: provider,
               fetched: tokenAccountUsage,
               published: snapshot)
        {
            return
        }
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
