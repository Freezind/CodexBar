import CodexBarCore
import Foundation

extension SettingsStore {
    func sessionAutoStartEnabled(for provider: UsageProvider) -> Bool {
        guard SessionAutoStarter.supports(provider) else { return false }
        return self.configSnapshot.providerConfig(for: provider.instanceID)?.sessionAutoStartEnabled ?? false
    }

    func setSessionAutoStartEnabled(_ enabled: Bool, for provider: UsageProvider) {
        guard SessionAutoStarter.supports(provider) else { return }
        // Affects background work so enabling it refreshes and evaluates the session right away.
        self.updateProviderConfig(provider: provider) { $0.sessionAutoStartEnabled = enabled }
    }
}
