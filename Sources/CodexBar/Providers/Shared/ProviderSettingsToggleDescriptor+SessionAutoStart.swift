import CodexBarCore
import SwiftUI

extension ProviderSettingsToggleDescriptor {
    @MainActor
    static func sessionAutoStart(
        provider: UsageProvider,
        cliName: String,
        context: ProviderSettingsContext) -> ProviderSettingsToggleDescriptor
    {
        let binding = Binding(
            get: { context.settings.sessionAutoStartEnabled(for: provider) },
            set: { context.settings.setSessionAutoStartEnabled($0, for: provider) })
        return ProviderSettingsToggleDescriptor(
            id: "\(provider.rawValue)-session-auto-start",
            title: "Auto-start 5h session",
            subtitle: [
                "When the 5-hour window is idle or has reset, sends one tiny \"ping\" through the `\(cliName)` CLI",
                "so the window starts counting. Uses a small amount of quota and runs as the CLI's signed-in account.",
                "Never fires while a session is already running, and at most once every 30 minutes.",
            ].joined(separator: " "),
            binding: binding,
            statusText: nil,
            actions: [],
            isVisible: nil,
            onChange: nil,
            onAppDidBecomeActive: nil,
            onAppearWhenEnabled: nil)
    }
}
